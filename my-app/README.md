# My App

This repository contains a simple Node.js application backed by MongoDB, orchestrated locally using Docker Compose, and used to demonstrate Tekton Pipelines for CI workflows such as cloning a repository and reading files.

The project is intentionally minimal and designed for learning Docker, Kubernetes, and Tekton fundamentals.

## CI/CD Pipeline with Tekton

### Tekton Triggers & EventListeners

This project uses **Tekton Triggers** to automate CI/CD pipelines based on Git events.

#### Setup EventListener

```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: EventListener
metadata:
  name: my-app-listener
spec:
  serviceAccountName: tekton-triggers-sa
  triggers:
    - name: github-push-trigger
      interceptors:
        - name: github
          ref:
            name: github
          params:
            - name: secretRef
              value:
                secretKey: github-token
                secretName: github-secret
      bindings:
        - ref: my-app-binding
      template:
        ref: my-app-template
```

#### Setup TriggerBinding

```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerBinding
metadata:
  name: my-app-binding
spec:
  params:
    - name: gitRepository
      value: $(body.repository.clone_url)
    - name: gitRevision
      value: $(body.head_commit.id)
    - name: gitBranch
      value: $(body.ref)
```

#### Setup TriggerTemplate

```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerTemplate
metadata:
  name: my-app-template
spec:
  params:
    - name: gitRepository
    - name: gitRevision
    - name: gitBranch
  resourcetemplates:
    - apiVersion: tekton.dev/v1beta1
      kind: PipelineRun
      metadata:
        generateName: my-app-run-
      spec:
        pipelineRef:
          name: my-app-pipeline
        params:
          - name: git-url
            value: $(tt.params.gitRepository)
          - name: git-revision
            value: $(tt.params.gitRevision)
```

#### Configure GitHub Webhook

1. Go to your GitHub repository Settings → Webhooks
2. Add webhook with EventListener URL: `http://<event-listener-url>`
3. Select events: `Push events` and `Pull requests`
4. Content type: `application/json`

#### Automation Features

- **Auto-trigger on push**: Pipeline runs automatically on Git push
- **Branch filtering**: Trigger specific pipelines per branch
- **Interceptors**: Validate GitHub signatures and filter events
- **PipelineRun generation**: Automatically creates pipeline executions

## Project Structure
.
├── docker-compose.yaml
├── Dockerfile
├── package.json
├── src/
│   └── index.js
└── README.md

## Services Overview
1. my-node-app

Node.js application

Built locally using Docker

Exposes port 3000

Connects to MongoDB via internal Docker network

2. mongo

Official MongoDB image

Uses a named volume for persistent storage

Credentials configured via environment variables

3. mongo-express

Web UI for MongoDB

Exposes port 8081

Connects to the mongo service internally

## Docker Compose Setup
Start all services
docker-compose up -d

Stop all services
docker-compose down

View running containers
docker ps

## Environment Variables

The Node app connects to MongoDB using:

MONGO_URI=mongodb://admin


MongoDB credentials:

Username:

Password: 

Accessing 

Node App: http://localhost:3000

Mongo Express: http://localhost:8081

## Tekton Pipeline Usage

This repository is used by a Tekton Pipeline that:

Clones the repository using the git-clone Task

Mounts the source code into a shared workspace

Reads and prints this README.md file using a follow-up Task

The Pipeline demonstrates:

Workspace sharing

Task dependencies

Parameterized Git repository cloning

## Requirements
Local Development

Docker

Docker Compose

Kubernetes / Tekton

Kubernetes cluster (e.g. Minikube)

Tekton Pipelines installed

Tekton git-clone Task installed

## Notes

This project is not intended for production use

Credentials should not be hardcoded rather secret key should be setup
Docker Compose is used only for local development

Tekton is used strictly for CI-style workflows, not runtime orchestration

## License

MIT License

If you want, the next logical step is to:

Create the show-readme Tekton Task that reads this file

Or evolve this into a proper build → image → deploy Tekton pipeline
