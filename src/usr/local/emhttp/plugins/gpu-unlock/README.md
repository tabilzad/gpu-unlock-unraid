**GPU Unlock**

Unlocks the full FP16/BF16 tensor rate of GeForce RTX 30 series cards (and, experimentally, RTX 20 and RTX 40 series) before the NVIDIA driver loads, with the gpu_unlock kernel module from Zagitta/gpu-unlock. The module is loaded by a modprobe rule right before nvidia at every boot, only for the cards you tick on the settings page (or name with gpu_unlock.targets= on the kernel command line). The plugin fetches the module built for your exact Unraid kernel from GitHub, also for a staged Unraid update, generates the required firmware locally with Docker, and reports each card's result after the boot. Settings, User Utilities, GPU Unlock.

Nothing in the NVIDIA driver is patched. Not affiliated with NVIDIA, Lime Technology or the gpu-unlock authors.
