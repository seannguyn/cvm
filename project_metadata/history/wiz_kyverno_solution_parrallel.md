Ok so I have the files around.

container-vulnerability-exemption is the frontend repo where tenant will interact with. Tenant mostly interact with container-vulnerability-exemption/unikube, container-vulnerability-exemption/pck depending on platform. focus on unikube for now.

I have move cert generation and image signing to dedicate folder: container-vulnerability-exemption/image-signing. so all instructions and related script should be there.

Make container-vulnerability-exemption/unikube/README.md compact and precise. mostly for running python script, rendering, run test, etc.

So the big change is: renaming to container-vulnerability-exemption.wiz and container-vulnerability-exemption.kyverno.

These are actually 2 options that I'm considering for the backend. The crux is that: tenants interact with: container-vulnerability-exemption, then for backend we have 2 competing solution:
1. container-vulnerability-exemption.wiz, which is pretty much mature and contains the terraform to create all the things needed
2. container-vulnerability-exemption.kyverno, which should create corresponding ImageValidatingPolicy, and PolicyException, similar concept to Wiz object. So make sure container-vulnerability-exemption/unikube have script to create k8s yaml corresponding to kyverno ImageValidatingPolicy, and PolicyException per each cluster. I have created the folder structure in the repo, just replace with correct content. I can do kubectl apply -f *.yaml to apply them.

Same as before, but more extended, the important README.md:
- container-vulnerability-exemption/image-signing/README.md
- container-vulnerability-exemption/unikube/README.md
- container-vulnerability-exemption.wiz/README.md
- container-vulnerability-exemption.kyverno/README.md
- project_metadata/project_summary.md

Make sure all scripts are run, tested, everything works