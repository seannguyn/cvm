Because there is hard limit on the number of ignore rules on wiz platform, each cluster now ONLY reference 2 ignore rules:
- global ignore rule for that environment
- cluster-specific ignore rule. all the images will be in this ignore rule. only support operator equals. and remove expired_at because there is no point to keep it when all images are in there.

this is a tradeoff that reduce the number of ignore rules at the expense of granular expired_at.
