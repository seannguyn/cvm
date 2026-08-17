delete wiz-v2_cicd_scan_policy.default_vuln, no longer need it. also delete: [golden.yaml](../container-vulnerability-exemption/unikube/exemptions/golden.yaml)

Rework terraform so that there should only be 1 statefile.

No more bootstrapping. the image v2_image_integrity_validator and all clusters wiz-v2_cicd_scan_policy, ignore rules should be in one statefile.

the ignore rule in global.yaml should be 1 ignore rule per environment, and all clusters in that environment should reference that globaly shared ignore rule + there own ignore rules

Any changes in wiz/container-vulnerability-exemption/unikube/exemptions/**/*.yaml should trigger a tf plan and apply. fix the python script accordingly. I think compute matrix will no longer be needed, since it will only be 1 terraform job.

Fix all relevant docs, code, tests, and make sure to check everything is working as expected. no bug slip through