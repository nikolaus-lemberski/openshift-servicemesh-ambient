# TODO

## Still to test

- [ ] `admin-scripts/cleanup.sh` on the cluster: open a Web Terminal, run the cleanup, check that no `controller.devfile.io` webhooks or devfile CRDs are left and that `oc exec` still works, then reinstall the Web Terminal
- [ ] `admin-scripts/cleanup-users.sh` after a real `setup-users.sh` run (Web Terminal DevWorkspaces in `<user>-terminal`, waypoints in `<user>-apps`)

## Optional

- [ ] ResourceQuota/LimitRange per user namespace in `setup-users.sh` (default off, for larger groups)
- [ ] `user-scripts/reset-my-namespaces.sh`: users reset their own namespaces (delete workshop resources, remove onboarding labels) without the admin
- [ ] Retake the screenshots that still show `servicemesh-apps`
