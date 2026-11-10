# 1. Getting Started

> [!IMPORTANT]
> **The user chapters are for the workshop users.** Your admin has already installed the Service Mesh and the observability stack and set up your user ([admin-chapters](../admin-chapters/01-installation.md)). You don't need any admin rights, you work in your own namespaces.

## Your namespaces

You've got three namespaces, `<user>` is your OpenShift user name (e.g. `user1`):

| Namespace         | Purpose                                                                                       |
| ----------------- | --------------------------------------------------------------------------------------------- |
| `<user>-apps`     | The demo apps in ambient mode (chapters 2–9)                                                 |
| `<user>-sidecar`  | A second copy of the apps with sidecars (chapter 10)                                         |
| `<user>-terminal` | Your Web Terminal. It's never part of the mesh, so you can call the apps from outside the mesh |

The other workshop users work in their own namespaces on the same cluster and share the mesh with you. You can only change your own namespaces.

## Open the Web Terminal

1. Log in to the OpenShift console with your workshop user.
2. Click the terminal icon **>_** in the top right corner of the console.
3. Select the project **`<user>-terminal`** and click **Start**. Don't use one of your app namespaces, the terminal would end up in the mesh.

It takes a moment until the terminal is ready. It's already logged in to OpenShift as your user.

## Get the workshop files

Clone this repository in the terminal and load the workshop environment:

```bash
git clone https://github.com/nikolaus-lemberski/openshift-servicemesh-ambient.git
cd openshift-servicemesh-ambient
source user-scripts/workshop-env.sh
```

`workshop-env.sh` does three things:

- It sets the variables the chapters use: `APPS_NS`, `SIDECAR_NS` and `TERMINAL_NS` with your namespace names, plus `KEYCLOAK_HOST`, `KIALI_URL` and `CONSOLE_URL`.
- It installs `istioctl` (in the version of the mesh) and `envsubst` from the workshop's download server.
- It switches to the project `<user>-apps`. Commands without `-n` go there.

Expected result:

```text
[INFO]  Installing istioctl 1.31.0 ...
[INFO]  Installing envsubst ...
[OK]    Workshop environment for user1
        APPS_NS=user1-apps  SIDECAR_NS=user1-sidecar  TERMINAL_NS=user1-terminal
        Current project: user1-apps
```

Check your namespaces and the tools:

```bash
oc projects
istioctl version --remote=false
```

You should see your three namespaces, the shared project `perses-dev` with the dashboards (read-only) and the `istioctl` client version.

> [!WARNING]
> If the Web Terminal restarts (e.g. after a long break), the variables and the installed tools are gone. Go back to the repository with `cd openshift-servicemesh-ambient` (clone it again if it's gone) and run `source user-scripts/workshop-env.sh`. What you've deployed in your namespaces stays.

## Run the commands

Run all commands of the workshop from the root directory of the repository in the Web Terminal. Some manifests contain variables like `${APPS_NS}`. The chapters apply them with `envsubst`, which replaces the variables with your values:

```bash
envsubst < k8s/... | oc apply -f -
```

Kiali and the OpenShift console only list the namespaces you have access to. Select your own namespace there, e.g. `user1-apps`.

> [!NOTE]
> The screenshots were taken in a single-user setup with the namespace `servicemesh-apps`. You see your own namespace `<user>-apps` instead.

## A second terminal tab

Some chapters generate traffic in a loop while you work on. Open a second tab with the **+** in the terminal window. A new tab is a new shell: the tools are there, but the variables aren't. Load the environment in the new tab as well:

```bash
cd openshift-servicemesh-ambient
source user-scripts/workshop-env.sh
```

---

[Overview](../README.md) | [2. Deploy and Onboard the Apps →](02-deploy-and-onboard.md)
