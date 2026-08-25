ok we are going with kyverno now, prod grade, AUDIT mode.

Remove all wiz related code in container-vulnerability-exemption. I also move container-vulnerability-exemption/poc to project_metadata/history/poc

For kyverno, the strategy is:

Phase 1:
- 1 catch all policy that glob everything to check for org signature. and policyexception for exempting images
- write a github issues to kyverno community about policy exception for ImageValidatingPolicy - ivpol skipping entire resources

phase 2:
- 1 imagevalidating policy for to check for all self-built images to be signed by org cert
- then policyexception for unsigned self-built. This will still break in the case of 1 signed and 1 unsigned since PolicyException is resource level.
- 1 validating policy for all other images. This will deny by default, and app team deploying these images will need policy exception. PolicyException for validating policy should be granular, and not check every single images right?

For now focus on phase 1, and render_kyverno have options for phase 2, analyse phase 2 feasibility. 

have matrix table for these usecase:

phase 1:
single-image pod
| image type | signed/unsigned | exempted in PEx | expected result | Actual
| self-built | signed image | None | admit | admit |
| self-built | unsigned image | None | deny | deny |
| self-built | unsigned image | YES | admit | admit |
| vendor | unsigned image | None | deny | deny |
| vendor | unsigned image | YES | admit | admit |

multi-images pod
| scenario (signed/unsigned) | expected result | Actual result|
| self-built signed + self-built unsigned | deny | deny |
| self-built unsigned + self-built unsigned excepted | deny | admit. This is loophole for ivpol that needs address |
| vendor image + vendor image excepted | deny | admit |
| vendor image + self-built unsigned image excepted | deny | admit. This is loophole for ivpol that needs address |
The number of container images in pod can scale but we can expect same result right?

phase 2:
single-image pod
| image type | signed/unsigned | exempted in PEx | expected result | Actual
| self-built | signed image | None | admit | admit |
| self-built | unsigned image | None | deny | deny |
| self-built | unsigned image | YES | admit | admit |
| vendor | unsigned image | None | deny | deny |
| vendor | unsigned image | YES | admit | admit |

multi-images pod
| scenario (signed/unsigned) | expected result | Actual result|
| self-built signed + self-built unsigned | deny | deny |
| self-built signed + self-built unsigned excepted | deny | admit. This is loophole for ivpol that needs address |
| vendor image + vendor image excepted | deny | deny. since this is validating policy and validating policy checks every image |
| vendor image + self-built unsigned image excepted | deny | admit. This is loophole that needs address |

For container-vulnerability-exemption/scripts, make sure:
- all scripts are kyverno related only
- kyverno_render produce files into container_exemptions instead of policy-exceptions
- ivpol should have normal naming, not "simple" or advanced. still keep 1.19 flag

I also move git mv container-vulnerability-exemption.wiz/ project_metadata/history

Rework all relevant README.md and tell me all the README.md I need to read to understand project end to end
