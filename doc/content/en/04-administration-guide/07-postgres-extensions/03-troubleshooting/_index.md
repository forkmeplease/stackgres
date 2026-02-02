---
title: Extension Troubleshooting
weight: 3
url: /administration/extensions/troubleshooting
description: Troubleshooting common PostgreSQL extension issues in StackGres.
showToc: true
---

This guide covers common issues with PostgreSQL extensions in StackGres and their solutions.

## Common Issues

### Extension Not Installing

**Symptom**: Extension specified in cluster spec but not available in PostgreSQL.

**Diagnosis**:
```bash
# Check cluster status for extension info
kubectl get sgcluster my-cluster -o yaml | grep -A20 extensions

# Check operator logs
kubectl logs -n stackgres -l app=stackgres-operator | grep -i extension

# Check if extension is available in PostgreSQL
kubectl exec my-cluster-0 -c postgres-util -- psql -c \
  "SELECT * FROM pg_available_extensions WHERE name = 'my_extension'"
```

**Solutions**:

1. **Extension not in repository**: Verify the extension exists in the StackGres extensions catalog

2. **Wrong PostgreSQL version**: Ensure the extension supports your PostgreSQL major version

3. **Network issues**: Check if pods can reach the extensions repository:
```bash
kubectl exec my-cluster-0 -c patroni -- \
  curl -I https://extensions.stackgres.io/postgres/repository
```

### Shared Library Extensions

Some extensions require loading via `shared_preload_libraries` and a cluster restart.

**Symptom**: Extension installed but functions not working.

**Solution**:

1. Check if extension requires shared library:
```bash
kubectl exec my-cluster-0 -c postgres-util -- psql -c \
  "SELECT * FROM pg_extension WHERE extname = 'my_extension'"
```

2. Add to PostgreSQL configuration via SGPostgresConfig:
```yaml
apiVersion: stackgres.io/v1
kind: SGPostgresConfig
metadata:
  name: my-pg-config
spec:
  postgresVersion: "16"
  postgresql.conf:
    shared_preload_libraries: 'timescaledb,pg_stat_statements'
```

3. Reference in cluster and restart:
```yaml
apiVersion: stackgres.io/v1
kind: SGCluster
metadata:
  name: my-cluster
spec:
  configurations:
    sgPostgresConfig: my-pg-config
```

4. Perform restart using SGDbOps:
```yaml
apiVersion: stackgres.io/v1
kind: SGDbOps
metadata:
  name: restart-for-extension
spec:
  sgCluster: my-cluster
  op: restart
  restart:
    method: ReducedImpact
```

### Extension Dependencies

**Symptom**: Extension fails with dependency error.

**Diagnosis**:
```bash
kubectl exec my-cluster-0 -c postgres-util -- psql -c \
  "CREATE EXTENSION my_extension CASCADE"
```

**Solution**: Add required dependencies to the cluster:
```yaml
spec:
  postgres:
    extensions:
      - name: plpgsql      # Dependency
      - name: my_extension # Extension requiring plpgsql
```

### Version Mismatch

**Symptom**: Error about incompatible extension version.

**Diagnosis**:
```bash
# Check installed vs requested version
kubectl exec my-cluster-0 -c postgres-util -- psql -c \
  "SELECT * FROM pg_available_extensions WHERE name = 'my_extension'"
```

**Solutions**:

1. **Update cluster spec** to match available version:
```yaml
spec:
  postgres:
    extensions:
      - name: my_extension
        version: '2.0.0'  # Use available version
```

2. **Upgrade extension** in PostgreSQL:
```bash
kubectl exec my-cluster-0 -c postgres-util -- psql -c \
  "ALTER EXTENSION my_extension UPDATE TO '2.0.0'"
```

### Extension Download Fails

**Symptom**: Extension download timeout or connection error.

**Diagnosis**:
```bash
# Check operator logs
kubectl logs -n stackgres -l app=stackgres-operator --tail=100 | grep -i download

# Test network connectivity
kubectl exec my-cluster-0 -c patroni -- \
  curl -v https://extensions.stackgres.io/
```

**Solutions**:

1. **Configure proxy** if behind firewall:
```yaml
apiVersion: stackgres.io/v1
kind: SGConfig
metadata:
  name: stackgres-config
spec:
  extensions:
    repositoryUrls:
      - https://extensions.stackgres.io/postgres/repository?proxyUrl=http%3A%2F%2Fproxy%3A8080
```

2. **Add retry logic**:
```yaml
repositoryUrls:
  - https://extensions.stackgres.io/postgres/repository?retry=5:10000
```

3. **Check DNS resolution**:
```bash
kubectl exec my-cluster-0 -c patroni -- nslookup extensions.stackgres.io
```

### Extension Requires Restart

**Symptom**: Extension installed but cluster shows `PendingRestart`.

**Diagnosis**:
```bash
kubectl get sgcluster my-cluster -o jsonpath='{.status.conditions}' | jq
```

**Solution**: Restart the cluster:
```yaml
apiVersion: stackgres.io/v1
kind: SGDbOps
metadata:
  name: apply-extension-restart
spec:
  sgCluster: my-cluster
  op: restart
  restart:
    method: ReducedImpact
    onlyPendingRestart: true
```

### PostGIS Installation Issues

PostGIS has specific requirements:

**Symptom**: PostGIS installation fails or functions missing.

**Solutions**:

1. **Install all PostGIS components**:
```bash
kubectl exec my-cluster-0 -c postgres-util -- psql -c "
  CREATE EXTENSION IF NOT EXISTS postgis;
  CREATE EXTENSION IF NOT EXISTS postgis_topology;
  CREATE EXTENSION IF NOT EXISTS postgis_raster;
  CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
  CREATE EXTENSION IF NOT EXISTS address_standardizer;
"
```

2. **Verify installation**:
```bash
kubectl exec my-cluster-0 -c postgres-util -- psql -c "SELECT PostGIS_Version()"
```

### TimescaleDB Installation Issues

**Symptom**: TimescaleDB functions not working.

**Solutions**:

1. **Add to shared_preload_libraries** (required):
```yaml
apiVersion: stackgres.io/v1
kind: SGPostgresConfig
metadata:
  name: timescale-config
spec:
  postgresVersion: "16"
  postgresql.conf:
    shared_preload_libraries: 'timescaledb'
    timescaledb.telemetry_level: 'off'
```

2. **Restart cluster** after configuration change

3. **Create extension** after restart:
```bash
kubectl exec my-cluster-0 -c postgres-util -- psql -c "CREATE EXTENSION timescaledb"
```

### Extension Removal Issues

**Symptom**: Cannot remove extension.

**Diagnosis**:
```bash
kubectl exec my-cluster-0 -c postgres-util -- psql -c \
  "SELECT * FROM pg_depend WHERE refobjid = (SELECT oid FROM pg_extension WHERE extname = 'my_extension')"
```

**Solutions**:

1. **Drop dependent objects** first:
```bash
kubectl exec my-cluster-0 -c postgres-util -- psql -c \
  "DROP EXTENSION my_extension CASCADE"
```

2. **Remove from cluster spec** after dropping:
```yaml
spec:
  postgres:
    extensions:
      # Remove the extension from this list
```

## Debug Mode

### Enable Extension Debug Logging

Add debug logging to see extension operations:

```yaml
apiVersion: stackgres.io/v1
kind: SGCluster
metadata:
  name: my-cluster
spec:
  nonProductionOptions:
    enabledFeatureGates:
      - debug-extensions
```

### Check Extension Status

```bash
# Full extension status
kubectl get sgcluster my-cluster -o json | jq '.status.extensions'

# Extensions to install
kubectl get sgcluster my-cluster -o json | jq '.status.toInstallPostgresExtensions'

# Installed per pod
kubectl get sgcluster my-cluster -o json | jq '.status.pods[].installedPostgresExtensions'
```

## Getting Help

If issues persist:

1. **Collect diagnostics**:
```bash
kubectl get sgcluster my-cluster -o yaml > cluster.yaml
kubectl logs -n stackgres -l app=stackgres-operator --tail=500 > operator.log
kubectl exec my-cluster-0 -c postgres-util -- psql -c "SELECT * FROM pg_available_extensions" > extensions.txt
```

2. **Check documentation**: [Extensions Catalog]({{% relref "01-introduction/08-extensions" %}})

3. **Open issue**: [GitHub Issues](https://github.com/ongres/stackgres/issues)

## Related Documentation

- [PostgreSQL Extensions Guide]({{% relref "04-administration-guide/07-postgres-extensions" %}})
- [Extension Versions]({{% relref "04-administration-guide/07-postgres-extensions/02-extension-versions" %}})
- [SGPostgresConfig Reference]({{% relref "06-crd-reference/03-sgpgconfig" %}})
