# RunPod auto-scaling workers

These scripts let a SwarmUI install with no GPU send jobs to RunPod. When a job arrives and no
worker is running, SwarmUI's Auto Scaling Backend starts a RunPod pod. The pod unpacks a saved
SwarmUI and ComfyUI install from a RunPod global volume, and reads the models from the same volume.
Once the worker has been idle for a set time, SwarmUI shuts it down and the pod deletes itself.

A global volume can be mounted in any RunPod data centre, so each pod runs wherever its GPU type
is in stock. Pods are on-demand Secure Cloud pods.

## What you need

- A RunPod account and an API key with read and write access.
- `curl` and `python3` on your machine.
- This repo pushed to a public git remote. The setup pod clones it.

## 1. Fill in the settings file

Copy `runpod.env.example` to `~/.config/swarmui/runpod.env` and fill it in. Keep this file outside
the repo, because it holds your API key. To use a different path, set `RUNPOD_ENV_FILE`.

`RUNPOD_GPU_TYPE` is the list of GPU types pods may use, separated by commas. Each new pod gets the
cheapest type on the list that's in stock. If none can be created, the job fails with each type's
error. To see each GPU type's ID, VRAM, price per hour and current stock:

```sh
launchtools/runpod/provision.sh gpus
```

## 2. Create the global volume

```sh
launchtools/runpod/provision.sh volume
```

Put the volume ID it prints into `RUNPOD_GLOBAL_VOLUME_ID`.

## 3. Install SwarmUI and the models onto the volume

```sh
launchtools/runpod/provision.sh setup
```

This starts a setup pod that clones the repo, installs .NET and downloads the models listed in
`models.txt` onto the volume. Then it starts SwarmUI. Follow the pod's logs in the RunPod console.

When SwarmUI is ready, open the address the script printed and finish the installer:

- Choose **Customize Settings**, not **Just Install**. Just Install downloads the default models
  onto the pod's own disk, where they're lost and can fill it.
- For who will use it, choose **Just Yourself, with LAN access**.
- Choose **ComfyUI** as the backend.
- Untick every model.

Protect the worker before you finish. Its address is public, so anyone who learns it could use
it:

1. Under **Server → Users**, add an account with the **owner** role. That role includes the
   **Automated Control** permission your local SwarmUI needs.
2. Under **Server → Server Configuration → User Authorization**, turn on **AuthorizationRequired**,
   turn off **AllowLocalhostBypass**, and save.
3. Reload the page and log in as the new account.
4. In the **User** tab, under **Swarm Auth Tokens**, click **Create New Auth Token**. Keep the token
   for step 5. It belongs to the account you're logged in as, so create it after step 3.

Then click **Shutdown Server** under **Server → Server Info**. The setup pod packs the install onto
the volume, copies the worker scripts there and deletes itself. If a step fails, the pod stays up
so you can read its logs. Delete it yourself when you're done:

```sh
launchtools/runpod/provision.sh delete POD_ID
```

Run this step again to update SwarmUI or ComfyUI, after you change the scripts in this folder, or
to change the models in `models.txt` (then run step 4 too). Worker pods use the copies saved on the volume. Each run
starts from the saved install, so your settings and login stay. Finished downloads are skipped.
Don't run jobs while setup is running: it rewrites the saved install.

## 4. Add stub models to your local SwarmUI

```sh
launchtools/runpod/make-stubs.sh
```

This writes a small header-only copy of each model marked `stub` in `models.txt` into your local
`Models/` folder. Your local SwarmUI needs these to list the models while no worker is running. Jobs
use the real files on the volume.

## 5. Configure your local SwarmUI

Start the SwarmUI container with your settings file as its environment. Copy
`launchtools/launch-standard-docker.sh` to `launchtools/custom-launch-docker.sh` (git ignores it)
and add this line to its `docker run` options:

```sh
--env-file "$HOME/.config/swarmui/runpod.env" \
```

The Docker image contains a copy of the repo, so run the launcher again after you pull changes to
these scripts.

In SwarmUI:

1. Go to **Server → Server Configuration** and set **ModelLoadOrderPreference** to **First Free**.
2. Go to **Server → Backends**, show advanced backends and add an **Auto Scaling Backend** with:
   - **StartScript**: `/SwarmUI/launchtools/runpod/autoscale-start.sh`
   - **MaxBackends**: `1`
   - **MinBackends**: `0`
   - **MinQueuedBeforeExpand**: `1`
   - **MinIdleTime**: `5` (minutes a worker stays up after its last job)
   - **OtherHeaders**: `Cookie: swarm_token=` followed by the token from step 3
3. Save.

When you generate, turn on **No Load Models** (an advanced parameter). RunPod's proxy cuts off any
single HTTP request after 100 seconds, and a separate model-load request for a large model can take
longer than that. With this option, the model loads as part of the generation, which runs over a
websocket and has no such limit. Save it in a preset with your other Wan settings.

## How a job runs

1. You submit a job. With no worker running, SwarmUI runs `autoscale-start.sh`.
2. The script creates a pod and gives SwarmUI the pod's RunPod proxy address. SwarmUI keeps trying
   to connect for about 15 minutes while the pod boots.
3. The pod runs `worker-start.sh` from the volume. It unpacks the install to the pod's own disk,
   links in the models from the volume and starts SwarmUI.
4. Your local SwarmUI connects, sends the job and keeps checking in with the worker.
5. After **MinIdleTime** with no jobs, your local SwarmUI shuts the worker down, and the pod
   deletes itself.

The pod also deletes itself in these cases:

- Your local SwarmUI stops checking in for 10 minutes, for example because your Mac went to sleep.
- The pod reaches `SWARM_WORKER_MAX_HOURS`.

## Costs

- **Global volume**: billed every month for the space used, whether or not a pod is running. Reads
  and writes have a small charge per request too.
- **Worker pod**: billed per second, from creation until it deletes itself. This includes boot
  time, unpacking the install, model loading and the idle time before shutdown.

If a pod can't delete itself, `worker-start.sh` logs an error and the pod keeps billing. To list
any pods these scripts created that are still there:

```sh
launchtools/runpod/provision.sh pods
```
