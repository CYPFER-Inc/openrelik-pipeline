# openrelik-pipeline

### Intro
Note: This version of the repository is designed to work with some private repositories that are specific to Cypfer
Cloned from: https://github.com/Digital-Defense-Institute/openrelik-pipeline

This repository provides an all-in-one DFIR solution by deploying Timesketch, OpenRelik, Velociraptor, and the custom OpenRelik Pipeline tool via Docker Compose. It allows users to send forensic artifacts (e.g., Windows event logs or full triage acquisitions generated with Velociraptor) to an API endpoint, which triggers a workflow to upload the files to OpenRelik and generate a timeline. Depending on the configuration, the workflow can use log2timeline (Plaso) or Hayabusa to produce the timeline and push it directly into Timesketch. This automated approach streamlines artifact ingestion and analysis, turning what used to be multiple separate processes into a more convenient, “push-button” deployment. 

### Notes

### Known Bugs
* [Timesketch postgres race condition](https://github.com/google/timesketch/issues/3263)

------------------------------

### Step 1 - Install Docker 
Follow the official installation instructions to [install Docker Engine](https://docs.docker.com/engine/install/).

### Step 2 - Clone the project and add a config.env file with details
### The detailed file will be provided to you if you are allowed access 
```bash
sudo -i
git clone https://github.com/CYPFER-Inc/openrelik-pipeline.git /opt/openrelik-pipeline
```
Copy the config.env file into the /opt/openrelik-pipeline directory

Change the `ENVIRONMENT` to dev (default)

Change `IP_ADDRESS` to your public or IPv4 address if deploying on a cloud server, a VM (the IP of the VM), or WSL (the IP of WSL).

Change the `Credentials` section for passwords

Optionally change the `VR_CONFIG_IMAGE` to point at a feature branch (defaults to :latest)

### Step 3 - Run the install script to deploy Timesketch, OpenRelik, Velociraptor, and the OpenRelik Pipeline
Depending on your connection, this can take 5-10 minutes.
```bash
chmod +x /opt/openrelik-pipeline/install.sh
/opt/openrelik-pipeline/install.sh 
```

> [!NOTE]  
> Your OpenRelik, Velociraptor, Timesketch usernames are `admin`, and the passwords are what you set above.

### Step 4 - Verify deployment
Verify that all containers are up and running.
```bash
docker ps -a
```

Access the web UIs:
* OpenRelik - http://0.0.0.0:8711
* Velociraptor - https://0.0.0.0:8889
* Timesketch - http://0.0.0.0 

Access the pipeline:
* OpenRelik Pipeline - http://0.0.0.0:5000

Again, if deploying elsewhere, or on a VM, or with WSL, use the IP you used for `$IP_ADDRESS`.

### Step 5 - Access 

#### With curl
You can now send files to it for processing and timelining.

We've provided an example with curl so it can be easily translated into anything else.

Generate a timeline with Hayabusa from your Windows event logs and push it into Timesketch:
```bash
curl -X POST -F "file=@/path/to/your/Security.evtx" http://$IP_ADDRESS:5000/api/hayabusa/timesketch
```

Generate a timeline with Plaso and push it into Timesketch:
```bash
curl -X POST -F "file=@/path/to/your/triage.zip" http://$IP_ADDRESS:5000/api/plaso/timesketch
```

#### With Velociraptor
In the repo, we've provided [several Velociraptor artifacts](./velociraptor). 

You can add them in the Velociraptor GUI in one of two ways:  
* In the `View Artifacts` section, click the `Add an Artifact` button and manually copy paste each one and save it  
* Via the Artifact Exchange    
    * Click `Server Artifacts`  
    * Click `New Collection`  
    * Select `Server.Import.ArtifactExchange`  
    * Click `Configure Parameters`  
    * Click on `Server.Import.ArtifactExchange`   
    * For the `ExchangeURL` enter the URL of `velociraptor_artifacts.zip` found [here](https://github.com/Digital-Defense-Institute/openrelik-pipeline/releases/latest)  
    * For the tag, choose something relevant, like `OpenRelikPipeline`  
    * Leave `ArchiveGlob` as is  
    * Click `Launch`  
    * You should now see all of them as `Server Monitoring` artifacts in the `Artifacts` page  

These are configured to hit each available endpoint:
* `/api/plaso`
* `/api/plaso/timesketch`
* `/api/hayabusa`
* `/api/hayabusa/timesketch`

You can configure them to run automatically by going to `Server Events` in the Velociraptor GUI and adding them to the server event monitoring table. 

By default, they are configured to run when the `Windows.Triage.Targets` artifact completes on an endpoint. 

It will zip up the collection, and send it through the pipeline into OpenRelik for processing.

**Steps:**  
1. Navigate to `Server Events` 
  ![alt text](screenshots/server_events_step-0.png)
2. Click `Update server monitoring table`
  ![alt text](screenshots/server_events_step-1.png)
3. Choose one or more triage artifacts to run in the background and click Launch
  ![alt text](screenshots/server_events_step-2.png)
4. The newly installed monitoring artifacts will soon show up in the `Select artifact` dropdown with logs
  ![alt text](screenshots/server_events_step-3.png)

### Importing Triage Artifacts

The main Velociraptor package no longer includes the necessary triage artifacts by default.  

You can download the `Windows.Triage.Targets` artifact from [here](https://triage.velocidex.com/docs/windows.triage.targets/), or simply use the built in `Server.Import.Extras` artifact to automatically download and import the latest version.

**Steps:**
  
1. Click `Server Artifacts` in the side menu
  ![alt text](screenshots/server.import.extras_step-0.png)
2. Click `New Collection`
  ![alt text](screenshots/server.import.extras_step-1.png)
3. Find the `Server.Import.Extras` artifact ![alt text](screenshots/server.import.extras_step-2.png)
4. Leave the default options to import everything, or remove others if you only wish to import the triage artifacts 
  ![alt text](screenshots/server.import.extras_step-3.png)
5.  Verify the `Windows.Triage.Targets` artifact is available under `View Artifacts` 
  ![alt text](screenshots/server.import.extras_step-4.png)

------------------------------
> [!IMPORTANT]  
> **I strongly recommend deploying OpenRelik and Timesketch with HTTPS**--additional instructions for Timesketch, OpenRelik, and Velociraptor are provided [here](https://github.com/google/timesketch/blob/master/docs/guides/admin/install.md#4-enable-tls-optional), [here](https://github.com/openrelik/openrelik.org/blob/main/content/guides/nginx.md), ahd [here](https://docs.velociraptor.app/docs/deployment/security/#deployment-signed-by-lets-encrypt). For this proof of concept, we're using HTTP. Modify your configs to reflect HTTPS if you deploy for production use. 

## Security Scanning
See [docs/trivy-scanning.md](docs/trivy-scanning.md) for local Trivy scan instructions
