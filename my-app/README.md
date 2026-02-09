This README assumes:

Public GitHub repo

Node.js app

Docker Compose setup

MongoDB + Mongo Express + ngrok delivery 

Tekton pipeline that clones and reads this file



My Node App – Docker & Tekton Demo

This repository contains a simple Node.js application backed by MongoDB, orchestrated locally using Docker Compose and used to demonstrate Tekton Pipelines for CI workflows such as cloning a repository and reading files.

The project is intentionally minimal and designed for learning Docker, Kubernetes, and Tekton fundamentals.

Project Structure
.
├── docker-compose.yaml
├── Dockerfile
├── package.json
├── src/
│   └── index.js
└── README.md

Services Overview
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

Docker Compose Setup
Start all services
docker-compose up -d

Stop all services
docker-compose down

View running containers
docker ps

Environment Variables

The Node app connects to MongoDB using:

MONGO_URI=mongodb://admin:admin123@mongo:27017/admin


MongoDB credentials:

Username: admin

Password: 

Accessing 

Node App: http://localhost:3000

Mongo Express: http://localhost:8081

Tekton Pipeline Usage

This repository is used by a Tekton Pipeline that:

Clones the repository using the git-clone Task

Mounts the source code into a shared workspace

Reads and prints this README.md file using a follow-up Task

The Pipeline demonstrates:

Workspace sharing

Task dependencies

Parameterized Git repository cloning

Requirements
Local Development

Docker

Docker Compose

Kubernetes / Tekton

Kubernetes cluster (e.g. Minikube)

Tekton Pipelines installed

Tekton git-clone Task installed

Notes

This project is not intended for production use

Credentials are hardcoded for simplicity

Docker Compose is used only for local development

Tekton is used strictly for CI-style workflows, not runtime orchestration

License

MIT License

If you want, the next logical step is to:

Create the show-readme Tekton Task that reads this file

Or evolve this into a proper build → image → deploy Tekton pipeline