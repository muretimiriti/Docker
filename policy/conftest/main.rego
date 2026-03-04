package main

deny[msg] {
  input.kind == "Deployment"
  input.metadata.name == "sample-node-app"
  not input.spec.template.spec.containers[_].readinessProbe
  msg := "sample-node-app deployment must define readinessProbe"
}

deny[msg] {
  input.kind == "Deployment"
  input.metadata.name == "sample-node-app"
  not input.spec.template.spec.containers[_].livenessProbe
  msg := "sample-node-app deployment must define livenessProbe"
}

deny[msg] {
  input.kind == "Deployment"
  input.metadata.name == "sample-node-app"
  not input.spec.template.spec.containers[_].resources.requests.cpu
  msg := "sample-node-app deployment must define resources.requests.cpu"
}

deny[msg] {
  input.kind == "Deployment"
  input.metadata.name == "sample-node-app"
  not input.spec.template.spec.containers[_].resources.requests.memory
  msg := "sample-node-app deployment must define resources.requests.memory"
}

deny[msg] {
  input.kind == "Deployment"
  input.metadata.name == "sample-node-app"
  not input.spec.template.spec.containers[_].resources.limits.cpu
  msg := "sample-node-app deployment must define resources.limits.cpu"
}

deny[msg] {
  input.kind == "Deployment"
  input.metadata.name == "sample-node-app"
  not input.spec.template.spec.containers[_].resources.limits.memory
  msg := "sample-node-app deployment must define resources.limits.memory"
}
