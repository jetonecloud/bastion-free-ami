---
name: Feature request
about: Suggest a control, module, or access path
title: ""
labels: enhancement
assignees: ""
---

## What you want to do

<!-- The use case, not the implementation. "I need to reach an
on-premises database through the access node" is more useful than
"add a variable for X". -->

## Why the current kit does not cover it

## Does AWS support it?

<!-- This is the important question. A lot of plausible requests turn
out to be things AWS does not offer -- IAM conditions on
port-forwarding parameters, for instance. If you have found the
relevant AWS documentation, link it; if you are not sure, say so and
we will check together. -->

## Would it weaken anything?

<!-- This kit's defaults are deliberately conservative. If the feature
needs an inbound rule, a broader IAM grant, extra tooling on the AMI,
or a public IP, say so -- it can probably still happen, behind an
off-by-default variable with the trade-off documented, the way `eice`
and the scale-to-zero schedule work. -->

- [ ] This needs no change to the hard requirements (no public IPs, no
      inbound rules, no SSH keys, no static credentials, IMDSv2 + hop
      limit 1, encrypted volumes, no secrets in the image)
- [ ] This would need an off-by-default variable and a documented
      trade-off
