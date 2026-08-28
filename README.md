# Beginner CI/CD Project: GitHub → Terraform → Docker → ECR → CodeBuild → EKS

## What you're building

A simple web app that automatically builds and deploys itself to Kubernetes (EKS) every time you push code to GitHub. The flow looks like this:

```
You push code to GitHub
        │
        ▼
CodePipeline notices the change (Source stage)
        │
        ▼
CodeBuild builds a Docker image and pushes it to ECR (Build stage)
        │
        ▼
CodeBuild runs `helm upgrade --install` against your EKS cluster (Deploy stage)
        │
        ▼
Your app is live and updated
```

**One important note on tooling:** AWS CodeDeploy only supports EC2, Lambda, and ECS — it does **not** support EKS. This project deploys via a small **Helm chart**, run by a second CodeBuild project in the Deploy stage, which is the standard way teams actually ship to Kubernetes. Everything else (GitHub, Terraform, Docker, ECR, CodeBuild, EKS) is exactly as requested.

---

## Prerequisites

Install these on your machine first:

| Tool | Purpose | Check install |
|---|---|---|
| AWS CLI | talk to your AWS account | `aws --version` |
| Terraform | create AWS infrastructure as code | `terraform -version` |
| Docker | build container images | `docker --version` |
| kubectl | talk to your Kubernetes cluster | `kubectl version --client` |
| Git | push code to GitHub | `git --version` |

You also need:
- An AWS account with admin access (this is a learning project — use a sandbox/free-tier-friendly account, not production)
- A GitHub account and a new empty repo, e.g. `eks-cicd-demo`
- AWS credentials configured locally: run `aws configure` and enter your access key, secret key, and region (use `us-east-1` to match this guide)

**Cost note:** an EKS cluster costs about $0.10/hour just to exist, plus the worker nodes (t3.small ~$0.02/hr each). Budget a couple dollars for this project and **delete everything when you're done** (Step 8 covers this).

---

## Step 1 — Create the sample app

This is a tiny Python Flask app. It doesn't need to be fancy — the point of this project is the pipeline, not the app.

Create a folder structure like this in your GitHub repo:

```
eks-cicd-demo/
├── app.py
├── requirements.txt
├── Dockerfile
├── buildspec.yml
├── buildspec-deploy.yml
├── helm/
│   └── eks-cicd-demo/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── deployment.yaml
│           └── service.yaml
└── terraform/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
```

**`app.py`**
```python
from flask import Flask
import os

app = Flask(__name__)

@app.route("/")
def hello():
    return f"Hello from CI/CD pipeline! Version: {os.environ.get('APP_VERSION', 'v1')}\n"

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
```

**`requirements.txt`**
```
flask==3.0.3
```

**Why:** this is the thing that gets built, containerized, and redeployed every time you push. Changing the text in `hello()` later is how you'll prove the pipeline actually works end to end.

---

## Step 2 — Write the Dockerfile

**`Dockerfile`**
```dockerfile
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

EXPOSE 5000
CMD ["python", "app.py"]
```

**Why:** Docker packages the app and everything it needs to run into one portable image. CodeBuild will run `docker build` using this exact file.

Test it locally before touching AWS:
```bash
docker build -t eks-cicd-demo .
docker run -p 5000:5000 eks-cicd-demo
# visit http://localhost:5000
```

---

## Step 3 — Write the Helm chart

Instead of raw Kubernetes YAML, this project deploys via a small **Helm chart** — Helm is a package manager for Kubernetes: you define your app's shape once with placeholders, and pass in the specific values (like which image tag to run) at deploy time. This is the same pattern most real teams use, and it's what makes "deploy version X" a single command instead of hand-editing YAML.

```
helm/
└── eks-cicd-demo/
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
        ├── deployment.yaml
        └── service.yaml
```

**`helm/eks-cicd-demo/Chart.yaml`** — metadata identifying this as a chart:
```yaml
apiVersion: v2
name: eks-cicd-demo
description: Helm chart for the eks-cicd-demo Flask app
type: application
version: 0.1.0
appVersion: "1.0"
```

**`helm/eks-cicd-demo/values.yaml`** — the default settings (the pipeline overrides `image.repository` and `image.tag` on every deploy, so you never edit this by hand):
```yaml
replicaCount: 2

image:
  repository: PLACEHOLDER_ECR_REPO_URI
  tag: latest
  pullPolicy: IfNotPresent

service:
  type: LoadBalancer
  port: 80
  targetPort: 5000
```

**`helm/eks-cicd-demo/templates/deployment.yaml`** — templated version of the old raw manifest, using `{{ .Values.* }}` placeholders instead of a hardcoded image name:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      containers:
        - name: {{ .Release.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.service.targetPort }}
```

**`helm/eks-cicd-demo/templates/service.yaml`**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-svc
spec:
  type: {{ .Values.service.type }}
  selector:
    app: {{ .Release.Name }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}
```

**Why:** `{{ .Release.Name }}` is filled in automatically by Helm based on whatever name you give the release when you install it (we'll use `eks-cicd-demo`). This means the same chart can be installed multiple times under different names — for example a `staging` release and a `prod` release — without copy-pasting YAML files.

---

## Step 4 — Provision AWS infrastructure with Terraform

This is the biggest step. Terraform will create: a VPC, an EKS cluster with worker nodes, an ECR repository, and the CodeBuild + CodePipeline resources. We lean on the official, well-maintained `terraform-aws-modules` so you don't have to hand-write dozens of resources.

**`terraform/variables.tf`**
```hcl
variable "aws_region" {
  default = "us-east-1"
}

variable "project_name" {
  default = "eks-cicd-demo"
}

variable "github_repo" {
  description = "format: your-username/eks-cicd-demo"
  type        = string
}
```

**`terraform/main.tf`**
```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------- Networking ----------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true # cheaper for a demo project

  tags = { "kubernetes.io/cluster/${var.project_name}" = "shared" }
}

# ---------- EKS Cluster ----------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name = var.project_name
  # No cluster_version pinned on purpose: AWS regularly retires old Kubernetes
  # versions from standard support, which then blocks new node groups on that
  # version (this is what caused the "AMI not supported" error). Leaving this
  # unset means Terraform always uses EKS's current default supported version.

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  # Lets IAM roles (not just the old aws-auth ConfigMap) be granted cluster access
  # below via access_entries -- this is what replaces the old manual "eksctl
  # create iamidentitymapping" step.
  authentication_mode = "API_AND_CONFIG_MAP"

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.small"]
      min_size       = 1
      max_size       = 2
      desired_size   = 2
    }
  }

  # Grants cluster access via IAM, instead of the old manual eksctl step
  access_entries = {
    # Lets the CodeBuild "deploy" project run `helm upgrade --install` against the cluster
    codebuild = {
      principal_arn = aws_iam_role.codebuild.arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
    # Lets whichever AWS identity ran `terraform apply` use kubectl/Helm against the cluster
    caller = {
      principal_arn = data.aws_caller_identity.current.arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}

# ---------- ECR (Docker image storage) ----------
resource "aws_ecr_repository" "app" {
  name                 = var.project_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

# ---------- GitHub connection (lets CodePipeline read your repo) ----------
resource "aws_codestarconnections_connection" "github" {
  name          = "${var.project_name}-github"
  provider_type = "GitHub"
}

# ---------- IAM role CodeBuild uses to build & push images ----------
resource "aws_iam_role" "codebuild" {
  name = "${var.project_name}-codebuild-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "codebuild_admin" {
  # Simplified for a learning project. In production, scope this down
  # to exactly ECR push + EKS describe-cluster permissions.
  role       = aws_iam_role.codebuild.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_codebuild_project" "build" {
  name         = "${var.project_name}-build"
  service_role = aws_iam_role.codebuild.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # required so Docker can build images inside CodeBuild

    environment_variable {
      name  = "ECR_REPO_URI"
      value = aws_ecr_repository.app.repository_url
    }
    environment_variable {
      name  = "EKS_CLUSTER_NAME"
      value = var.project_name
    }
  }
}

# Deploy stage: runs `helm upgrade --install` against the cluster using the
# image tag and Helm chart handed off from the Build stage's artifacts.
resource "aws_codebuild_project" "deploy" {
  name         = "${var.project_name}-deploy"
  service_role = aws_iam_role.codebuild.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec-deploy.yml"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = false # no Docker needed here, just kubectl/Helm

    environment_variable {
      name  = "ECR_REPO_URI"
      value = aws_ecr_repository.app.repository_url
    }
    environment_variable {
      name  = "EKS_CLUSTER_NAME"
      value = var.project_name
    }
  }
}

# ---------- IAM role CodePipeline itself uses ----------
resource "aws_iam_role" "codepipeline" {
  name = "${var.project_name}-codepipeline-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "codepipeline_admin" {
  role       = aws_iam_role.codepipeline.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess" # simplified for learning
}

resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket        = "${var.project_name}-pipeline-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

data "aws_caller_identity" "current" {}

# ---------- The pipeline itself ----------
resource "aws_codepipeline" "pipeline" {
  name     = "${var.project_name}-pipeline"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.github.arn
        FullRepositoryId = var.github_repo
        BranchName       = "main"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "DeployWithHelm"
      category        = "Build" # CodeBuild actions always use category "Build", even in a Deploy stage
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.deploy.name
      }
    }
  }
}
```

**`terraform/outputs.tf`**
```hcl
output "ecr_repo_url" {
  value = aws_ecr_repository.app.repository_url
}

output "github_connection_arn" {
  value = aws_codestarconnections_connection.github.arn
  description = "You must approve this connection in the AWS Console before the pipeline works — see Step 5."
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}
```

**Why each piece exists, in plain English:**
- **VPC module** — Kubernetes needs its own private network to run in.
- **EKS module** — this is the actual Kubernetes cluster, with 2 small worker nodes to run your app's containers.
- **ECR repository** — a private Docker Hub, hosted by AWS, where your built images live.
- **CodeStar connection** — the "handshake" that lets AWS securely read your GitHub repo (you approve it once, manually, in the console — GitHub tokens can't be fully automated for security reasons).
- **`build` CodeBuild project** — builds the Docker image, pushes it to ECR, and hands off the image tag + Helm chart to the next stage.
- **`deploy` CodeBuild project** — runs `helm upgrade --install` against the cluster using what the build stage handed off. This is what replaced the old native "CodeDeploy/EKS action" approach, since that path can't run Helm.
- **Access entries on the EKS cluster** — grant the `deploy` project's IAM role (and your own AWS identity) permission to actually talk to Kubernetes; being an AWS admin doesn't automatically mean Kubernetes trusts you.
- **CodePipeline** — the conductor: watches GitHub, triggers the build project, then triggers the deploy project, in order, every time you push code.

Now apply it:
```bash
cd terraform
terraform init
terraform plan
terraform apply    # type "yes" when prompted — takes ~15 minutes, EKS is slow to create
```

---

## Step 5 — Approve the GitHub connection (one-time, manual)

Terraform created the GitHub connection, but AWS requires a human to click "Authorize" for security reasons.

1. Go to **AWS Console → Developer Tools → Settings → Connections**
2. Find the connection named `eks-cicd-demo-github` — it will show status **Pending**
3. Click it → **Update pending connection** → log into GitHub and authorize AWS
4. Status changes to **Available**

**Why:** without this, CodePipeline has no permission to see your repo, and the pipeline will fail at the Source stage.

---

## Step 6 — Write the buildspecs (tell CodeBuild what to do)

There are now two buildspecs — one per CodeBuild project — since building the image and deploying it with Helm are separate jobs.

**`buildspec.yml`** (in the repo root) — the **Build** stage: builds and pushes the image, then hands off the tag and Helm chart:
```yaml
version: 0.2

phases:
  pre_build:
    commands:
      - echo Logging in to ECR...
      - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $ECR_REPO_URI
      - IMAGE_TAG=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c 1-8)
  build:
    commands:
      - echo Building Docker image...
      - docker build -t $ECR_REPO_URI:$IMAGE_TAG .
  post_build:
    commands:
      - echo Pushing image to ECR...
      - docker push $ECR_REPO_URI:$IMAGE_TAG
      - echo Recording image tag for the Deploy stage...
      - echo $IMAGE_TAG > image-tag.txt

artifacts:
  files:
    - image-tag.txt
    - helm/**/*
```

**Why:** three plain-English steps — (1) log in to ECR, (2) build the image and tag it with the git commit hash so every version is traceable, (3) push it to ECR and write that tag to a small text file. That file, plus the whole `helm/` folder, get packaged up as the artifact the Deploy stage receives — this is how the new image version and the chart both reach the next stage.

**`buildspec-deploy.yml`** (in the repo root) — the **Deploy** stage: installs Helm and runs the actual deployment:
```yaml
version: 0.2

phases:
  install:
    commands:
      - echo Installing Helm...
      - curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
      - chmod +x get_helm.sh
      - ./get_helm.sh
  pre_build:
    commands:
      - echo Connecting kubectl/Helm to the EKS cluster...
      - aws eks update-kubeconfig --name $EKS_CLUSTER_NAME --region $AWS_DEFAULT_REGION
      - IMAGE_TAG=$(cat image-tag.txt)
  build:
    commands:
      - echo Deploying with Helm...
      - >
        helm upgrade --install eks-cicd-demo ./helm/eks-cicd-demo
        --set image.repository=$ECR_REPO_URI
        --set image.tag=$IMAGE_TAG
        --wait --timeout 5m
  post_build:
    commands:
      - echo Deployment complete. Current release status:
      - helm status eks-cicd-demo
```

**Why:** `helm upgrade --install` is Helm's "deploy or update, whichever applies" command — the first run installs the release, every run after that updates it in place. `--set image.tag=$IMAGE_TAG` is what actually ships your new code: it overrides the placeholder in `values.yaml` with the real tag that was just pushed to ECR. `--wait` makes the pipeline actually fail if the new pods don't come up healthy, instead of reporting success the instant `helm` exits.

---

## Step 7 — Connect kubectl to your cluster

EKS uses its own access-control layer on top of IAM — being an IAM admin doesn't automatically mean Kubernetes trusts you. The Terraform in Step 4 already handles this: it grants both the `deploy` CodeBuild role *and* whichever AWS identity ran `terraform apply` admin access to the cluster (via `access_entries` in `main.tf`), so there's no manual permissions step here anymore.

You just need to point your own local `kubectl`/`helm` at the cluster (useful for checking on things — the pipeline itself connects independently, using its own IAM role):

```bash
aws eks update-kubeconfig --name eks-cicd-demo --region us-east-1
kubectl get nodes    # should list your 2 worker nodes
```

**Why:** `update-kubeconfig` writes the cluster's connection details to your local kubeconfig file so `kubectl` (and Helm, which reads the same file) knows where to send commands. If `kubectl get nodes` returns your nodes, your access entry is working correctly.

---

## Step 8 — Push your code and watch it deploy

```bash
git add .
git commit -m "Initial commit — trigger pipeline"
git push origin main
```

Go to **AWS Console → CodePipeline** and watch the three stages light up green in order: Source → Build → Deploy. First run takes a few minutes.

Once it's done, you can check the release directly with Helm:
```bash
helm list
helm status eks-cicd-demo
```

Then get your app's public URL:
```bash
kubectl get svc eks-cicd-demo-svc
```
Copy the `EXTERNAL-IP` value and open it in a browser (or `curl` it) — you should see your Flask app's message.

**Prove the loop works:** edit the message text in `app.py`, `git push` again, and refresh the pipeline — a new image builds and deploys automatically with no manual steps.

---

## Step 9 — Clean up (don't skip this — avoids ongoing charges)

```bash
kubectl delete svc eks-cicd-demo-svc   # deletes the AWS load balancer first
cd terraform
terraform destroy
```

Also manually delete the CodeStar GitHub connection in the console if `terraform destroy` doesn't remove it.

---

## What you now understand, end to end

- **GitHub** → where your code and Helm chart live
- **Terraform** → created every piece of AWS infrastructure as reusable code instead of manual console clicks
- **Docker** → packaged your app into a portable image
- **ECR** → stored that image privately in AWS
- **CodeBuild (build project)** → automated the build-and-push step on every commit
- **Helm** → packaged the Kubernetes deployment itself as a reusable, versioned chart instead of raw YAML
- **CodeBuild (deploy project)** → ran `helm upgrade --install` against the cluster on every commit, using an EKS access entry for authentication instead of the old CodeDeploy/EKS-native-action approach (since CodeDeploy doesn't support EKS)

If you'd like, a natural next step is adding a **staging vs. production** pipeline branch, or trying **GitOps** (ArgoCD/Flux watching the chart in Git instead of the pipeline pushing changes directly) — happy to walk through either.
