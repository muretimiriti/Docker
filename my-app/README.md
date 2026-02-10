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

## Issues Found (Code Review)

Reviewed on 2026-02-10.

### Critical

- Committed private SSH key in `my-app/secrets.yaml:8` (`ssh-privatekey`). Revoke/rotate immediately and remove it from git history.
- Committed Docker registry credentials in `my-app/docker-credentials.yaml:6` (`config.json`). Rotate credentials and remove from git history.
- Committed and hardcoded passwords/credentials:
- `my-app/.env:2` `my-app/.env:4` `my-app/.env:7`
- `my-app/docker-compose.yaml:11`
- `my-app/mongo-deployment.yaml:21` `my-app/mongo-deployment.yaml:24`
- `my-app/mongo-express-deployment.yaml:21` `my-app/mongo-express-deployment.yaml:24`
- `my-app/node-app-deployment.yaml:21`
- Tekton EventListener manifest is invalid YAML structure: `my-app/event-listener.yaml:7` has `triggers:` at the top level, but it must be under `spec:` (Kubernetes will reject it).
- Tekton PipelineRun references a pipeline that does not exist: `my-app/tekton.pipelinerun.yml:7` references `clone-read`, but the pipeline present is `tekton-trigger-listeners` in `my-app/tekton.pipeline.yml:4`.

### High

- Stored XSS risk: unescaped user input is injected into HTML in `my-app/server.js:58` through `my-app/server.js:66`. A user can store `<script>` in profile fields and it will execute on `/profile`.
- Missing validation and incorrect error semantics:
- Invalid Mongo ObjectId in `/profile` can produce a 500 via cast error from `User.findById` (`my-app/server.js:55`) instead of returning a 400.
- `User.findByIdAndUpdate` does not run validators by default; updates are currently unvalidated (`my-app/server.js:79`).
- No authentication/authorization: anyone can update any profile by posting an `id` (`my-app/server.js:75`).

### Medium

- `docker-compose` env wiring is incorrect for Mongo and Mongo Express (values are set to literal strings instead of actual values or `${VAR}` interpolation):
- `my-app/docker-compose.yaml:24` `my-app/docker-compose.yaml:25`
- `my-app/docker-compose.yaml:35` `my-app/docker-compose.yaml:36` `my-app/docker-compose.yaml:37` `my-app/docker-compose.yaml:38`
- Dockerfile runs `nodemon` in the container (`my-app/Dockerfile:18`), and `nodemon` is in production dependencies (`my-app/package.json:17`). This is fine for local dev but not for production images.
- Tests are not runnable: `my-app/package.json:6` exits 1 even though Jest is configured in `my-app/jest.config.js:5`.

### Repo Hygiene / Docs

- `my-app/node_modules/` is committed. This should be removed from git and added to `.gitignore`.
- README structure does not match the repo (README mentions `src/index.js`, but app entrypoint is `my-app/server.js`).

## License

MIT License

If you want, the next logical step is to:

Create the show-readme Tekton Task that reads this file

Or evolve this into a proper build → image → deploy Tekton pipeline
