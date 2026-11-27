# RunPod auto-scaling workers

These scripts let a SwarmUI install with no GPU send jobs to RunPod. When a job arrives and no
worker is running, SwarmUI's Auto Scaling Backend starts a RunPod pod. The pod runs SwarmUI with
ComfyUI from a network volume that holds the install and the models. Once the worker has been idle
for a set time, SwarmUI shuts it down and the pod deletes itself.

Pods are on-demand Secure Cloud pods, because RunPod network volumes only work with Secure Cloud.

## What you need

- A RunPod account and an API key with read and write access.
- `curl` and `python3` on your machine.
- This repo pushed to a public git remote. The setup pod clones it.

## 1. Fill in the settings file

Copy `runpod.env.example` to `~/.config/swarmui/runpod.env` and fill it in. Keep this file outside
the repo, because it holds your API key. To use a different path, set `RUNPOD_ENV_FILE`.

Check that `RUNPOD_GPU_TYPE` matches an ID that RunPod lists:

```sh
launchtools/runpod/provision.sh gpus
```

## 2. Create the network volume

The volume lives in one data centre, and every worker pod runs there. So the GPUs you can get are
the ones that data centre has free at the time. The volume can't move, so choose a data centre
that usually has your GPU type.

With `RUNPOD_DATA_CENTER` left empty, this command lists data centres that support network volumes
and have your GPU type:

```sh
launchtools/runpod/provision.sh volume
```

The list is in order of preference: Oceania, Asia, North America with the US west coast first, then
other regions. The **GPU NOW** column shows how many of your GPU type are free at this moment. It
changes within minutes, so it's only a rough guide. If a data centre shows `NONE` or `LOW` every
time you check, consider another one. Put your choice in `RUNPOD_DATA_CENTER` and run the command
again to create the volume.
Then put the volume ID it prints into `RUNPOD_NETWORK_VOLUME_ID`.

To see the list again later, run `provision.sh datacenters`.

## 3. Install SwarmUI and the models onto the volume

```sh
launchtools/runpod/provision.sh setup
```

This starts a setup pod that clones the repo onto the volume, installs .NET and downloads the
models listed in `models.txt`. Then it starts SwarmUI. Follow the pod's logs in the RunPod console.

When SwarmUI is ready, open the address the script printed and finish the installer:

- Choose **ComfyUI (Local)** as the backend and the standard (NVIDIA) install.
- Choose no extra models.

Protect the worker before you finish. Its address is public, so anyone who learns it could use
it:

1. Under **Server → Server Configuration → User Authorization**, turn on **AuthorizationRequired**
   and create an account.
2. Give that account the **Automated Control** permission.
3. In the **User** tab, create an auth token. Keep it for step 5.

Then delete the setup pod:

```sh
launchtools/runpod/provision.sh delete POD_ID
```

To change the models later, edit `models.txt` and run steps 3 and 4 again. Finished downloads are
skipped.

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
3. The pod runs `worker-start.sh`, which starts SwarmUI from the volume.
4. Your local SwarmUI connects, sends the job and keeps checking in with the worker.
5. After **MinIdleTime** with no jobs, your local SwarmUI shuts the worker down, and the pod
   deletes itself.

The pod also deletes itself in these cases:

- Your local SwarmUI stops checking in for 10 minutes, for example because your Mac went to sleep.
- The pod reaches `SWARM_WORKER_MAX_HOURS`.

## Costs

- **Network volume**: billed every month, whether or not a pod is running.
- **Worker pod**: billed per second, from creation until it deletes itself. This includes boot
  time, model loading and the idle time before shutdown.

If a pod can't delete itself, `worker-start.sh` logs an error and the pod keeps billing. To list
any pods these scripts created that are still there:

```sh
launchtools/runpod/provision.sh pods
```
