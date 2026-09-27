# Enterprise EKS Infrastructure with Terraform

Terraform configuration for an enterprise-hardened, fully private Amazon EKS cluster using EKS Auto Mode, a resilient multi-AZ VPC, and an AWS Systems Manager (SSM) bastion for administrative access without inbound ports.

Commands you can copy and run are shown in `bash` blocks. Blocks labeled **Example output** show what the CLI may print; do not copy or run those blocks. Configuration examples use `hcl`, `yaml`, or `bash` fences as appropriate.

## Architecture Highlights

- **Private EKS control plane:** Public API endpoint access is disabled with `endpoint_public_access = false`.
- **EKS Auto Mode:** AWS manages node provisioning, patching, VPC CNI, CoreDNS, and load balancing without manual node groups or Karpenter configuration.
- **Resilient 2-AZ VPC:**
  - `/20` private subnets, providing approximately 4,090 IPs per AZ.
  - Two dedicated NAT gateways (one per AZ) balancing high availability with cost optimization.
  - An S3 gateway endpoint to bypass NAT gateway data charges for S3 traffic.
  - VPC Flow Logs stored in CloudWatch with configurable retention (default: 90 days).
- **Defense-in-depth bastion:**
  - One `t3.micro` EC2 instance in Private Subnet A.
  - Zero open inbound ports. Outbound access is restricted to HTTPS (443) and DNS (53).
  - IMDSv2 is enforced and an encrypted `gp3` root volume is enabled.
- **Security and governance:**
  - AWS KMS customer-managed key for Kubernetes secrets envelope encryption.
  - Control plane logging enabled for `api`, `audit`, `authenticator`, `controllerManager`, and `scheduler`.
- **EKS access entries:** IAM identities are mapped without relying on the legacy `aws-auth` ConfigMap.
- **Remote state:** S3 state storage with AES-256 server-side encryption and DynamoDB state locking.
- **Automated HTTPS & Custom Domain**:
  * Free AWS Certificate Manager (ACM) wildcard TLS certificate (`*.yourdomain.com`).
  * Automated DNS delegation from external registrars (Namecheap, GoDaddy, Cloudflare, etc.) into AWS Route 53.
  * Ingress SSL termination with automatic HTTP-to-HTTPS redirect (port 80 -> 443).
- **Automated Ingress DNS (ExternalDNS)**:
  * Runs in-cluster using **EKS Pod Identity** (zero static AWS keys).
  * Automatically creates and cleans up Route 53 DNS records when `Ingress` resources are deployed.
- **Zero-Secret CI/CD with GitHub Actions OIDC**:
  * Authenticates GitHub Actions pipelines to AWS without long-lived static AWS access keys.
  * Private **Amazon ECR** repository with KMS encryption, automated vulnerability scanning on push, and 30-day lifecycle retention.
- **In-Cluster GitOps with ArgoCD**:
  * ArgoCD deployed inside the private cluster to synchronize manifests via the GitOps pull model.
- **Zero-Secret Storage & Management (External Secrets Operator)**:
  * Uses the **"Empty Container" pattern**: Terraform provisions the secret container, KMS encryption, and IAM permissions; real credentials are never stored in Git or Terraform state files.
- **External Secrets Operator (ESO)** synchronizes credentials from **AWS Secrets Manager** directly into native Kubernetes Secrets in pod memory using **EKS Pod Identity**.
- **Automated Cluster Observability & Container Insights**:
  * Managed **Amazon CloudWatch Observability Add-on** powered by AWS Distro for OpenTelemetry (ADOT).
  * Real-time Container Insights dashboards tracking per-pod CPU/Memory saturation, OOMKill events, and network I/O.
  * In-cluster agents authenticated securely via **EKS Pod Identity** (`CloudWatchAgentServerPolicy`).

## Prerequisites

Install the following tools on your workstation:

1. [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
2. [Session Manager Plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) for port forwarding
3. [Terraform 1.6 or later](https://developer.hashicorp.com/terraform/downloads)
4. [kubectl](https://kubernetes.io/docs/tasks/tools/)

Authenticate your AWS CLI with permissions to create VPC, IAM, EC2, KMS, and EKS resources:
```bash
aws sts get-caller-identity
```

## 1. Bootstrap Remote State Storage

Before running Terraform, create the S3 bucket and DynamoDB table used for remote state. Run these commands once:

```bash
export AWS_REGION="us-east-1"
export BUCKET_NAME="mycompany-prod-terraform-state-878311410498"
export TABLE_NAME="terraform-state-locks"

# 1. Create S3 Bucket
aws s3api create-bucket \
  --bucket $BUCKET_NAME \
  --region $AWS_REGION

# 2. Enable Bucket Versioning
aws s3api put-bucket-versioning \
  --bucket $BUCKET_NAME \
  --versioning-configuration Status=Enabled

# 3. Enable Server-Side Encryption (SSE-S3)
aws s3api put-bucket-encryption \
  --bucket $BUCKET_NAME \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# 4. Block All Public Access
aws s3api put-public-access-block \
  --bucket $BUCKET_NAME \
  --public-access-block-configuration '{
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
  }'

# 5. Create DynamoDB Table for Concurrency Locking
aws dynamodb create-table \
  --table-name $TABLE_NAME \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region $AWS_REGION
```

## 2. Deploy the Infrastructure

### Phase 2.1: Configure Variables & Create Route 53 Hosted Zone
1. Open **`terraform.tfvars`** and ensure your domain name and repository settings are configured:
   ```hcl
   domain_name       = "movinvinusandha.me"
   github_repository = "movinvinusandha/*"
  ```

2. Initialize Terraform and create the Route 53 zone:

  ```bash
# Initialize Terraform and configure the S3 backend
terraform init

# Provision only the Route 53 Zone first:
terraform apply -target=aws_route53_zone.primary

# Retrieve your 4 AWS Name Servers:
terraform output route53_name_servers
```

**Example output:**

```text
route53_name_servers = [
  "ns-123.awsdns-45.com",
  "ns-678.awsdns-90.net",
  "ns-111.awsdns-22.org",
  "ns-333.awsdns-44.co.uk",
]
```

### Phase 2.2: Delegate at Your External Registrar (One-Time)
1. Log into your external domain registrar dashboard.
2. Go to DNS / Name Servers Settings for your domain.
3. Switch to Custom Name Servers and paste the 4 AWS Name Servers retrieved from step
4. Save changes. (Allows AWS Route 53 to control DNS for your domain).

### Phase 2.3: Apply Complete Infrastructure
Run the complete apply to provision the VPC, EKS Auto Mode cluster, bastion, and validated ACM certificate:

```bash
# Initialize Terraform and configure the S3 backend
terraform init

# Validate the configuration
terraform validate

# Generate an execution plan
terraform plan -out=tfplan

# Apply exactly the saved plan
terraform apply tfplan
```

The saved plan becomes stale if Terraform state changes after the plan is created. In that case, run `terraform plan -out=tfplan` again before applying.

> (AWS Certificate Manager will automatically validate via Route 53 and issue the certificate).

## 3. Connect to the Private Cluster

Because the EKS API endpoint is private, administrative commands (`kubectl`) route through an encrypted SSM tunnel via the private bastion.

Use two terminal windows.

### Terminal 1: Start the SSM Port Forwarding Tunnel

Run the connection command generated by Terraform:

```bash
eval "$(terraform output -raw connect_script)"
```

Alternatively, run the command manually:

```bash
INSTANCE_ID=$(terraform output -raw bastion_instance_id)
CLUSTER_DOMAIN=$(terraform output -raw eks_api_server_domain)

aws ssm start-session \
  --target $INSTANCE_ID \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$CLUSTER_DOMAIN\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"6443\"]}"
```

**Example output:**

```text
Starting session with SessionId: user-0123456789abcdef0
Port 6443 opened for sessionId user-0123456789abcdef0.
Waiting for connections...
```

> **Important:** `Waiting for connections...` means the tunnel is active and listening on `127.0.0.1:6443`. Leave this terminal open.

### Terminal 2: Configure and Use kubectl

Open a second terminal window and fetch the cluster context from AWS:

```bash
aws eks update-kubeconfig --region us-east-1 --name prod-eks-cluster
```

Route `kubectl` through the active tunnel with TLS validation:

```bash
CLUSTER_DOMAIN=$(terraform output -raw eks_api_server_domain)
CONTEXT=$(kubectl config current-context)

kubectl config set-cluster $CONTEXT \
  --server=https://127.0.0.1:6443 \
  --tls-server-name=$CLUSTER_DOMAIN
```

Test the connection:

```bash
kubectl get nodes
```

When the connection works, Terminal 1 logs a connection message:

**Example output:**

```text
Connection accepted for session [user-0123456789abcdef0]
```

Terminal 2 returns the active EKS nodes:

**Example output:**

```text
NAME                                STATUS   ROLES    AGE   VERSION
ip-10-0-1-xxx.ec2.internal          Ready    <none>   10m   v1.36.x-eksbuild.x
```


## Step 4: Deploy ExternalDNS and Verify Custom Domain HTTPS

> ℹ️ **Run all commands in Terminal 2** (while the SSM tunnel remains active in Terminal 1).

### 4.1. Apply Cluster IngressClass and ExternalDNS Controller
Deploy the required EKS Auto Mode `IngressClass` and the `ExternalDNS` controller (which uses EKS Pod Identity):

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: alb
  labels:
    app.kubernetes.io/name: LoadBalancerController
  annotations:
    ingressclass.kubernetes.io/is-default-class: "true"
spec:
  controller: eks.amazonaws.com/alb
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-dns
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: external-dns
rules:
  - apiGroups: [""]
    resources: ["services", "endpoints", "pods"]
    verbs: ["get", "watch", "list"]
  - apiGroups: ["extensions", "networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "watch", "list"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: external-dns-viewer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: external-dns
subjects:
  - kind: ServiceAccount
    name: external-dns
    namespace: kube-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: external-dns
  namespace: kube-system
spec:
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: external-dns
  template:
    metadata:
      labels:
        app: external-dns
    spec:
      serviceAccountName: external-dns
      containers:
        - name: external-dns
          image: registry.k8s.io/external-dns/external-dns:v0.15.1
          args:
            - --source=ingress
            - --provider=aws
            - --policy=upsert-only
            - --aws-zone-type=public
            - --registry=txt
            - --txt-owner-id=eks-cluster
EOF
```

### 4.2. Deploy Secure HTTPS Workload
Replace app.yourdomain.com with your actual subdomain:

```bash
CERT_ARN=$(terraform output -raw acm_certificate_arn)

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-web-app
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: secure-web-app
  template:
    metadata:
      labels:
        app: secure-web-app
    spec:
      containers:
      - name: web
        image: public.ecr.aws/docker/library/nginx:alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 250m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: secure-service
  namespace: default
spec:
  type: ClusterIP
  selector:
    app: secure-web-app
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: secure-ingress
  namespace: default
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: "${CERT_ARN}"
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
spec:
  ingressClassName: alb
  rules:
  # Replace with your actual domain or subdomain
  - host: app.yourdomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: secure-service
            port:
              number: 80
EOF
```

### 4.3. Verify End-to-End DNS and SSL Encryption

Run these commands to verify ExternalDNS, the HTTP-to-HTTPS redirect, and the TLS certificate:

```bash
# Check ExternalDNS logs to verify Route 53 was updated automatically:
kubectl logs -n kube-system -l app=external-dns --tail=20

# Test HTTP to HTTPS redirect:
curl -I "http://app.yourdomain.com"

# Verify Valid TLS/SSL Certificate:
curl -Iv "https://app.yourdomain.com"
```

**Example output:**

```text
time="2026-09-21T12:00:00Z" level=info msg="Applying provider record change" record=app.yourdomain.com type=A
HTTP/1.1 301 Moved Permanently
Location: https://app.yourdomain.com/
HTTP/2 200
server: awselb/2.0
```

The exact ExternalDNS log messages, ALB headers, and timestamps will vary. The important results are a successful Route 53 update, an HTTP redirect to HTTPS, and a valid certificate for the requested hostname.

### Verify ALB Creation and DNS Propagation

Watch the secure Ingress until the AWS ALB address is assigned. This usually takes one to two minutes:

```bash
kubectl get ingress secure-ingress -w
```

**Example output:**

```text
NAME             CLASS   HOSTS               ADDRESS                                         PORTS     AGE
secure-ingress   alb     app.yourdomain.com   k8s-default-securei-1234567890.us-east-1.elb.amazonaws.com   80, 443   2m
```

Test the endpoint:

```bash
ALB_URL=$(kubectl get ingress secure-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -I "http://$ALB_URL"
```

**Example output:**

```text
HTTP/1.1 301 Moved Permanently
Location: https://app.yourdomain.com/
```

> **Note:** If `curl` returns `Could not resolve host`, wait 60–90 seconds for DNS records to propagate.

## 5. Automated GitOps and CI/CD Pipeline

Because the cluster API is 100% private, deployments follow the **GitOps Pull Model**:
1. **GitHub Actions** builds the container and pushes it to Amazon ECR via OIDC.
2. **ArgoCD** (running inside the private cluster) detects Git changes and syncs them locally.

---

### 5.1. Deploy ArgoCD and Expose the Dashboard
In **Terminal 2** (with your SSM tunnel active in Terminal 1):

```bash
# 1. Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. Configure ArgoCD for ALB SSL termination
kubectl patch configmap argocd-cmd-params-cm -n argocd \
  -p '{"data":{"server.insecure":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd

# 3. Expose via ALB Ingress
CERT_ARN=$(terraform output -raw acm_certificate_arn)

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: "${CERT_ARN}"
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/backend-protocol: HTTP
spec:
  ingressClassName: alb
  rules:
  - host: argocd.movinvinusandha.me
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
EOF
```

**Example output:**

```text
namespace/argocd created
configmap/argocd-cmd-params-cm patched
deployment.apps/argocd-server restarted
deployment.apps/argocd-server condition met
ingress.networking.k8s.io/argocd-server-ingress created
```

### 5.2. Access the ArgoCD Web Console

Retrieve the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

**Example output:**

```text
<generated-admin-password>
```

Open your browser and navigate to:

```text
https://argocd.movinvinusandha.me
```

Sign in with username `admin` and the password retrieved above.

### 5.3. Configure the GitHub Actions Workflow

In your application source repository, add `.github/workflows/ci-cd.yaml` to build and push Docker images to Amazon ECR without AWS access keys:

```yaml
name: Build & Push to ECR

on:
  push:
    branches: [ "main" ]

permissions:
  id-token: write
  contents: read

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Authenticate to AWS via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          # Paste output from: terraform output -raw github_actions_role_arn
          role-to-assume: arn:aws:iam::878311410498:role/prod-eks-cluster-github-actions-role
          aws-region: us-east-1

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build, Tag, and Push Image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          ECR_REPOSITORY: my-app
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
```

The workflow does not print a single fixed result. A successful run appears as a green workflow run in GitHub Actions, and the image is available in the configured ECR repository.

## Step 6: Enterprise Secrets Management (AWS Secrets Manager + ESO)

In a GitOps workflow, all manifests live in Git, but credentials must **never be committed to Git or stored in Terraform state**.

With this setup:
1. **Terraform** provisions an empty secret container and IAM Pod Identity permissions.
2. Credentials are added directly to AWS Secrets Manager outside of Git.
3. **External Secrets Operator (ESO)** synchronizes credentials into Kubernetes Pods in memory.

---

### 6.1. Inject Real Credentials into AWS Secrets Manager (One-Time)
Run this command from your terminal to populate the secret container created by Terraform. Replace the placeholder values locally; never commit real credentials to Git or paste them into this README:

```bash
SECRET_NAME=$(terraform output -raw secrets_manager_secret_name)

aws secretsmanager put-secret-value \
  --secret-id "$SECRET_NAME" \
  --secret-string '{"DATABASE_URL":"postgresql://<username>:<password>@<database-host>:5432/<database-name>","API_KEY":"<api-key>","JWT_SECRET":"<jwt-secret>"}' \
  --region us-east-1
```

**Example output:**

```text
{
  "ARN": "arn:aws:secretsmanager:us-east-1:123456789012:secret:prod-eks-cluster/production/app-AbCdEf",
  "Name": "prod-eks-cluster/production/app",
  "VersionStages": ["AWSCURRENT"]
}
```

### 6.2. Install External Secrets Operator (ESO) and CRDs

In Terminal 2, with the SSM tunnel active in Terminal 1:

```bash
# 1. Install CRDs using Server-Side Apply (Required because CRDs exceed the 256KB client-side limit)
kubectl apply --server-side -f https://raw.githubusercontent.com/external-secrets/external-secrets/main/deploy/crds/bundle.yaml

# 2. Create namespace and ServiceAccount linked in Terraform
kubectl create namespace external-secrets
kubectl create serviceaccount external-secrets-sa -n external-secrets

# 3. Install ESO via Helm
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets \
  --set installCRDs=false \
  --set serviceAccount.create=false \
  --set serviceAccount.name=external-secrets-sa
```

**Example output:**

```text
namespace/external-secrets created
serviceaccount/external-secrets-sa created
NAME: external-secrets
STATUS: deployed
```

### 6.3. Connect ESO to AWS Secrets Manager (ClusterSecretStore)

Deploy the `ClusterSecretStore` using the GA `v1` API. Because the IAM role is linked through EKS Pod Identity, ESO detects credentials automatically:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
EOF
```

**Example output:**

```text
clustersecretstore.external-secrets.io/aws-secrets-manager created
```

Verify the connection:

```bash
kubectl get clustersecretstore
```

**Example output:**

```text
NAME                  AGE   STATUS   READY
aws-secrets-manager   10s   Valid    True
```

### 6.4. Define the ExternalSecret Resource

Commit this manifest to Git to declare which keys to sync into native Kubernetes Secrets:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: app-secrets-sync
  namespace: default
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: app-production-secrets # Native K8s secret generated automatically
    creationPolicy: Owner
  data:
    - secretKey: DATABASE_URL
      remoteRef:
        key: prod-eks-cluster/production/app
        property: DATABASE_URL
    - secretKey: API_KEY
      remoteRef:
        key: prod-eks-cluster/production/app
        property: API_KEY
    - secretKey: JWT_SECRET
      remoteRef:
        key: prod-eks-cluster/production/app
        property: JWT_SECRET
EOF
```

**Example output:**

```text
externalsecret.external-secrets.io/app-secrets-sync created
```

### 6.5. Verify Secret Synchronization

Check the sync status:

```bash
kubectl get externalsecret app-secrets-sync
```

**Example output:**

```text
NAME               STORE                  REFRESH INTERVAL   STATUS         READY
app-secrets-sync   aws-secrets-manager   1h                 SecretSynced   True
```

Verify that ESO generated the native Kubernetes Secret:

```bash
kubectl get secret app-production-secrets
```

**Example output:**

```text
NAME                     TYPE     DATA   AGE
app-production-secrets   Opaque   3      1m
```

Do not print production secret values in shared terminals, CI logs, or documentation. To verify a value locally when necessary:

```bash
kubectl get secret app-production-secrets -o jsonpath="{.data.DATABASE_URL}" | base64 -d && echo
```

**Example output:**

```text
<database-connection-string>
```

### 6.6. Consume the Secret in Workload Pods

Your application deployments can consume these credentials securely through environment variables:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-api
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend-api
  template:
    metadata:
      labels:
        app: backend-api
    spec:
      containers:
      - name: api
        image: public.ecr.aws/docker/library/nginx:alpine
        env:
          - name: DB_CONNECTION_STRING
            valueFrom:
              secretKeyRef:
                name: app-production-secrets
                key: DATABASE_URL
          - name: API_KEY
            valueFrom:
              secretKeyRef:
                name: app-production-secrets
                key: API_KEY
```

## Step 7: Observability and Health Monitoring

Application metrics, pod performance, and container logs stream to CloudWatch through the **Amazon CloudWatch Observability EKS add-on**.

### 7.1. Verify CloudWatch Agent Pods

In Terminal 2, with the SSM tunnel active in Terminal 1:

```bash
kubectl get pods -n amazon-cloudwatch
```

**Example output:**

```text
NAME                                      READY   STATUS    RESTARTS   AGE
amazon-cloudwatch-observability-agent    1/1     Running   0          5m
amazon-cloudwatch-observability-fluent   1/1     Running   0          5m
```

Pod names may vary with the add-on version. The agents should report `Running` and all expected containers should be ready.

### 7.2. Inspect Live Metrics in CloudWatch

Open the AWS CloudWatch console in `us-east-1` and navigate to **Insights > Container Insights**. Select **EKS Pods** to inspect:

- Pod CPU and memory utilization.
- Container restarts, `CrashLoopBackOff`, and out-of-memory terminations (`OOMKilled`).
- Pod network and storage throughput.

Navigate to **Logs > Log groups** to view structured application logs under `/aws/containerinsights/prod-eks-cluster/application`.

## Managing Team Access

To grant access to other engineers or CI/CD pipelines, update `access_entries` in `eks-cluster.tf`:

This is a Terraform configuration example, not a command to run by itself.

```hcl
access_entries = {
  # Current deployer
  bootstrap_deployer = {
    principal_arn = data.aws_caller_identity.current.arn
    policy_associations = {
      admin = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope = { type = "cluster" }
      }
    }
  }

  # Add an IAM Identity Center (SSO) Role
  devops_team = {
    principal_arn = "arn:aws:iam::878311410498:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_AdministratorAccess_1234567890abcdef"
    policy_associations = {
      admin = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope = { type = "cluster" }
      }
    }
  }
}
```

Run `terraform plan` and `terraform apply` to push access changes without restarting cluster components.

## Teardown

To delete all provisioned resources:

1. Delete workloads that created AWS ALBs:

    ```bash
    kubectl delete ingress --all --all-namespaces
    ```

2. Destroy the infrastructure:

    ```bash
    terraform destroy
    ```

