
Write a custom image admission controller, that takes the best of kyverno imagevalidatingpolicy and Wiz Admission Controller, Image Trust feature.

Image Admission Controller source code, written in Go. it should follow k8s framework for custom image admission controller. 

The model is: 
- It should check all images deployed into cluster. The admission controller mode can either be AUDIT/BLOCK. default is AUDIT.
- the ImageTrust crds should have an array of rules, where each rule contains a list of image prefixes and a list of CA certificates, and priority
  - so the intention is something like AWS Security Group, first match wins.
  - so it can be something like:

```yaml
rules:
  - priority: 10
    description: "trust cert from vendor_1"
    imagePrefix: 
      - "some.vendor_1.registry.domain"
    ca: |
      -----BEGIN CERTIFICATE-----
      ... 
      -----END CERTIFICATE-----
  - priority: 20
    description: "trust cert from vendor_2"
    imagePrefix: 
      - "some.vendor_2.registry.domain"
    ca: |
      -----BEGIN CERTIFICATE-----
      ... 
      -----END CERTIFICATE-----
  - priority: 999
    description: "catch all rule"
    imagePrefix: 
      - "*"
    ca: |
      -----BEGIN CERTIFICATE-----
      ... internal org CA ...
      -----END CERTIFICATE-----
```

This means ImageTrust CRDs mean that all images deployed into cluster MUST be signed by some CA (either vendor CA or internal org CA). If an image is not signed, it will be blocked by the admission controller unless it matches a PolicyException CRD rule.

- crds so that users can configure which CA to trust so that Notation can verify image signatures.
- PolicyException CRD: should have: imagePrefix list, expiry, approver's name, jira ticket, reason: RISK_ACCEPTED, FALSE_POSITIVE.
- when a pod/cronjob is deploy, it should check for all images in that workload: initContainers, containers, ephemeralContainers to see if the image(s)
  - match PolicyException CRD rule, and PolicyException is still valid, if yes, skip signature verification.
  - if not match any PolicyException CRD rule, then check if it is signed and trusted by the relevant CA in ImageTrust CRD.

All image admission decision MUST be recorded as audit event with details, even in BLOCK mode, and the actual workload was BLOCKED or CREATED

- Then a ImageAdmission reviewer UI deploy to the clusters can read these records and show them in the UI. Make sure there are metrics on containers being blocked/excepted/signed/not-signed, etc comprehensive so that users can run prometheus/grafana query.

Solution can be deploy as a helm chart, with values files. For ImageAdmission, use the repository secrets specified in pod manifest. if it is ECR repo, use the IRSA, assuming that IAM roles are created, bind to service account that the admission controller pod can use.

Make sure the code is blazing fast so that image admission doesn't add any noticeable latency to pod creation.

Evaluate this solution requirements. Is it simple yet effective for the goal it is trying to accomplish?
