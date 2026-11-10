# 3. Teardown

There are two levels of cleanup: remove the workshop users and keep the mesh for the next workshop, or remove everything.

## Remove the workshop users

Between two workshops, remove what [setup-users.sh](02-user-setup.md) created:

```bash
./admin-scripts/cleanup-users.sh
```

This deletes:

- the user namespaces `<user>-apps`, `<user>-sidecar` and `<user>-terminal`, with everything the users deployed in them (apps, gateways, waypoints, policies, Web Terminals)
- the per-user ClusterRoles and ClusterRoleBindings
- the shared objects: the namespace `workshop-tools`, the group `servicemesh-workshop-users` and the shared RBAC in the namespaces `ztunnel` and `perses-dev`

The script finds the objects by their labels (`servicemesh-workshop/user` and `servicemesh-workshop/shared`), so it also cleans up users that have been removed from the identity provider in the meantime. It asks before it deletes anything, pass `-y` to skip the question.

To remove only some users, e.g. users who have left, pass their names:

```bash
./admin-scripts/cleanup-users.sh user3 user4
```

Then only the namespaces and the RBAC of these users are removed, and the users are taken out of the group. The tools server and the shared RBAC stay for the other users.

Expected result: the script waits until the namespaces are gone and ends with `Workshop users removed!`. Check that no user namespaces are left:

```bash
oc get namespaces -l servicemesh-workshop/user
```

> [!NOTE]
> The `User` and `Identity` objects stay, they belong to the identity provider. The users' traces stay in the Tempo storage until the retention expires.

For the next workshop, run `./admin-scripts/setup-users.sh` again.

## Remove everything

To remove the whole installation from [chapter 1](01-installation.md):

```bash
./admin-scripts/cleanup.sh
```

The script first runs `cleanup-users.sh`, so that no namespace is in the ambient mesh anymore when Istio is removed. Then it removes Keycloak, the console plugins, the tracing and observability stack, Istio, the operators (including the Web Terminal) and their namespaces, and reverts the cluster settings changed by the installation.

> [!WARNING]
> The DevWorkspace Operator comes with the Web Terminal, but OpenShift Dev Spaces uses it as well. `cleanup.sh` only removes it if `install.sh` installed it and no other DevWorkspaces exist on the cluster.

---

[← 2. Workshop Users](02-user-setup.md) | [Overview](../README.md)
