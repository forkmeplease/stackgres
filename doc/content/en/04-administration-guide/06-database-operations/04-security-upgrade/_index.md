---
title: Security Upgrade
weight: 4
url: /administration/database-operations/security-upgrade
description: How to perform security upgrades on StackGres clusters.
showToc: true
---

A security upgrade updates the container images and operating system-level packages of a StackGres cluster without changing the PostgreSQL major or minor version. This is distinct from a [minor version upgrade]({{% relref "04-administration-guide/06-database-operations/06-minor-version-upgrade" %}}) which changes the PostgreSQL version itself. Security upgrades address vulnerabilities in the base container images, libraries, and system packages. StackGres allows you to perform security upgrades declaratively through [SGDbOps]({{% relref "06-crd-reference/08-sgdbops" %}}).

## When to Use

- When new container images are available with security patches
- To apply OS-level security fixes without changing PostgreSQL versions
- As part of a regular maintenance schedule to keep clusters up to date

## Upgrade Methods

The security upgrade operation supports two methods:

| Method | Description |
|--------|-------------|
| `InPlace` | Restarts each Pod in the existing cluster one at a time. Does not require additional resources but causes longer service disruption when only a single instance is present. |
| `ReducedImpact` | Creates a new updated replica before restarting existing Pods. Requires additional resources to spawn the temporary replica but minimizes downtime. Recommended for production environments. |

## Basic Security Upgrade

Perform a security upgrade using the reduced impact method:

```yaml
apiVersion: stackgres.io/v1
kind: SGDbOps
metadata:
  name: security-upgrade
spec:
  sgCluster: my-cluster
  op: securityUpgrade
  securityUpgrade:
    method: ReducedImpact
```

## In-Place Security Upgrade

For non-production environments or when additional resources are not available:

```yaml
apiVersion: stackgres.io/v1
kind: SGDbOps
metadata:
  name: security-upgrade-inplace
spec:
  sgCluster: my-cluster
  op: securityUpgrade
  securityUpgrade:
    method: InPlace
```

> For production environments with a single instance, the in-place method will cause service disruption for the duration of the Pod restart. Use `ReducedImpact` when possible.

## Monitoring the Operation

After creating the SGDbOps resource, you can monitor the progress:

```
kubectl get sgdbops security-upgrade -w
```

The operation status is tracked in `SGDbOps.status.conditions`. When the operation completes successfully, the status will show `Completed`.

## Related Documentation

- [SGDbOps CRD Reference]({{% relref "06-crd-reference/08-sgdbops" %}})
- [Minor Version Upgrade]({{% relref "04-administration-guide/06-database-operations/06-minor-version-upgrade" %}})
- [Major Version Upgrade]({{% relref "04-administration-guide/06-database-operations/07-major-version-upgrade" %}})
