package agent_policy
import future.keywords.in
import future.keywords.if
import future.keywords.every
default AddARPNeighborsRequest := true
default AddSwapRequest := false
default CloseStdinRequest := true
default CopyFileRequest := false
default CreateContainerRequest := false
default CreateSandboxRequest := false
default DestroySandboxRequest := true
default GetDiagnosticDataRequest := false
default GetMetricsRequest := false
default GetOOMEventRequest := true
default GuestDetailsRequest := true
default ListInterfacesRequest := true
default ListRoutesRequest := true
default MemHotplugByProbeRequest := false
default OnlineCPUMemRequest := false
default PauseContainerRequest := false
default PullImageRequest := false
default ReadStreamRequest := true
default RemoveContainerRequest := true
default RemoveStaleVirtiofsShareMountsRequest := true
default ReseedRandomDevRequest := true
default ResumeContainerRequest := false
default SetGuestDateTimeRequest := true
default SetPolicyRequest := false
default SignalProcessRequest := false
default StartContainerRequest := true
default StartTracingRequest := false
default StatsContainerRequest := true
default StopTracingRequest := false
default TtyWinResizeRequest := false
default UpdateContainerRequest := false
default UpdateEphemeralMountsRequest := false
default UpdateInterfaceRequest := true
default UpdateRoutesRequest := true
default WaitProcessRequest := true
default WriteStreamRequest := false
default ExecProcessRequest := false

# Allow sandbox creation only if no guest OCI hooks are injected and no kernel modules
# are loaded — prevents host-side injection of hooks or modules into the guest VM.
CreateSandboxRequest if {
    input.guest_hook_path == ""
    count(input.kernel_modules) == 0
}

# Allow exact system networking files
CopyFileRequest if {
    allowed_system_paths := {
        "/etc/resolv.conf",
        "/etc/hosts",
        "/etc/hostname"
    }
    allowed_system_paths[input.path]
}

# Allow Kubernetes mounted volumes (ConfigMaps, Secrets, Tokens)
# Kata Containers stages host-side volume mounts inside this shared guest directory:
CopyFileRequest if {
    startswith(input.path, "/run/kata-containers/shared/containers/")
}

# Only allow pulling images whose registry path matches an image_guest_pull source
# declared in policy_data — blocks pulling arbitrary images inside the guest VM.
PullImageRequest if {
    some container in policy_data.containers
    some allowed_storage in container.storages
    allowed_storage.driver == "image_guest_pull"
    startswith(input.image, allowed_storage.source)
}

# Restrict signals to graceful shutdown (SIGTERM=15) and force kill (SIGKILL=9) only —
# prevents arbitrary signal injection into guest processes from the host.
SignalProcessRequest if { input.signal == 15 }
SignalProcessRequest if { input.signal == 9 }

# Allow container creation only if the requested args and all storages exactly match
# a known container entry in policy_data — binds each container to its declared identity.
CreateContainerRequest if {
    some container in policy_data.containers
    input.OCI.Process.Args == container.OCI.Process.Args
    count(input.storages) > 0
    every storage in input.storages {
        storage_allowed(storage, container)
    }
}

# A storage is allowed only if it matches a declared entry in the container's policy_data
# storages list by both driver and source prefix — rejects unexpected drivers or registries.
storage_allowed(storage, container) if {
    some allowed_storage in container.storages
    storage.driver == allowed_storage.driver
    startswith(storage.source, allowed_storage.source)
}

policy_data := {
    "containers": [
        {
            "OCI": {
                "Process": {
                    "Args": ["/usr/bin/pod"]
                }
            },
            "storages": [
                {"driver": "image_guest_pull", "source": "pause"}
            ]
        },
        {
            "OCI": {
                "Process": {
                    "Args": ["/bin/cp", "-r", "/model/.", "/models-cache/"]
                }
            },
            "storages": [
                {"driver": "image_guest_pull", "source": "{model_image_repo}:"},
                {"driver": "image_guest_pull", "source": "{model_image_repo}@"},
                {"driver": "ephemeral", "source": "tmpfs"}
            ]
        },
        {
            "OCI": {
                "Process": {
                    "Args": ["/bin/bash", "-c", "bash /app/decrypt.sh && python /app/app.py"]
                }
            },
            "storages": [
                {"driver": "image_guest_pull", "source": "{app_image_repo}:"},
                {"driver": "image_guest_pull", "source": "{app_image_repo}@"},
                {"driver": "ephemeral", "source": "tmpfs"}
            ]
        }
    ]
}
