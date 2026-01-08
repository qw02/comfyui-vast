#!/usr/bin/env bash

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

if ! which aria2 > /dev/null 2>&1; then
    echo "Installing aria2..."
    apt-get update && apt-get install -y aria2
else
    echo "aria2 is already installed"
fi

if ! which curl > /dev/null 2>&1; then
    echo "Installing curl..."
    apt-get update && apt-get install -y curl
else
    echo "curl is already installed"
fi

# Start SageAttention build in the background
echo "Starting SageAttention build..."
(
    export EXT_PARALLEL=4 NVCC_APPEND_FLAGS="--threads 8" MAX_JOBS=32
    cd /tmp
    git clone https://github.com/thu-ml/SageAttention.git
    cd SageAttention
    git reset --hard 68de379
    pip install -e .
    echo "SageAttention build completed" > /tmp/sage_build_done
) > /tmp/sage_build.log 2>&1 &
SAGE_PID=$!
echo "SageAttention build started in background (PID: $SAGE_PID)"

jupyter-lab \
  --ip=0.0.0.0 --port=8888 \
  --allow-root --no-browser \
  --NotebookApp.token='' --NotebookApp.password='' \
  --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True \
  --notebook-dir=/ &
JUP_PID=$!
echo "Jupyter started (PID: $JUP_PID)"

CUSTOM_NODES_DIR="/ComfyUI/custom_nodes"

# Change to the directory
cd "$CUSTOM_NODES_DIR" || exit 1

# Function to download a model using huggingface-cli
download_model() {
    local url="$1"
    local full_path="$2"

    local destination_dir=$(dirname "$full_path")
    local destination_file=$(basename "$full_path")

    mkdir -p "$destination_dir"

    # Simple corruption check: file < 10MB or .aria2 files
    if [ -f "$full_path" ]; then
        local size_bytes=$(stat -f%z "$full_path" 2>/dev/null || stat -c%s "$full_path" 2>/dev/null || echo 0)
        local size_mb=$((size_bytes / 1024 / 1024))

        if [ "$size_bytes" -lt 10485760 ]; then  # Less than 10MB
            echo "🗑️  Deleting corrupted file (${size_mb}MB < 10MB): $full_path"
            rm -f "$full_path"
        else
            echo "✅ $destination_file already exists (${size_mb}MB), skipping download."
            return 0
        fi
    fi

    # Check for and remove .aria2 control files
    if [ -f "${full_path}.aria2" ]; then
        echo "🗑️  Deleting .aria2 control file: ${full_path}.aria2"
        rm -f "${full_path}.aria2"
        rm -f "$full_path"  # Also remove any partial file
    fi

    echo "📥 Downloading $destination_file to $destination_dir..."

    # Download without falloc (since it's not supported in your environment)
    aria2c \
      -x 16 -s 16 -k 1M \
      --continue=true \
      --log-level=warn \
      --summary-interval=30 \
      --file-allocation=none \
      -d "$destination_dir" \
      -o "$destination_file" \
      "$url" \
      >/dev/null 2>&1 &

    echo "Download started in background for $destination_file"
}

# Define base paths
MODELS_DIR="/ComfyUI/models"

# Download models
echo "Downloading models..."
mkdir -p "$MODELS_DIR/detection"
download_model "https://huggingface.co/Wan-AI/Wan2.2-Animate-14B/resolve/main/process_checkpoint/det/yolov10m.onnx" "$MODELS_DIR/detection/yolov10m.onnx"
download_model "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_data.bin" "$MODELS_DIR/detection/vitpose_h_wholebody_data.bin"
download_model "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_model.onnx" "$MODELS_DIR/detection/vitpose_h_wholebody_model.onnx"
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/SCAIL/Wan21-14B-SCAIL-preview_comfy_bf16.safetensors" "$MODELS_DIR/diffusion_models/Wan21-14B-SCAIL-preview_comfy_bf16.safetensors"
download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" "$MODELS_DIR/vae/wan_2.1_vae.safetensors"
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors" "$MODELS_DIR/text_encoders/umt5-xxl-enc-bf16.safetensors"
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_Uni3C_controlnet_fp16.safetensors" "$MODELS_DIR/controlnet/Wan21_Uni3C_controlnet_fp16.safetensors"
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank256_bf16.safetensors" "$MODELS_DIR/loras/lightx2v_I2V_14B_480p_cfg_step_distill_rank256_bf16.safetensors"
download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" "$MODELS_DIR/clip_vision/clip_vision_h.safetensors"
download_model "https://github.com/isarandi/nlf/releases/download/v0.3.2/nlf_l_multi_0.3.2.torchscript" "$MODELS_DIR/nlf/nlf_l_multi_0.3.2.torchscript"

# ═══════════════════════════════════════════════════════════
# Custom nodes to clone/update
# ═══════════════════════════════════════════════════════════
REPOS=(
    "https://github.com/cubiq/ComfyUI_essentials"
    "https://github.com/kijai/ComfyUI-SCAIL-Pose"
    "https://github.com/shootthesound/comfyUI-LongLook"
    "https://github.com/kijai/ComfyUI-WanAnimatePreprocess"
)

# Clone or update repositories
for repo in "${REPOS[@]}"; do
    folder_name=$(basename "$repo" .git)
    target_dir="$CUSTOM_NODES_DIR/$folder_name"

    if [ ! -d "$target_dir" ]; then
        echo "Cloning $folder_name..."
        git -C "$CUSTOM_NODES_DIR" clone "$repo"
    else
        echo "Updating $folder_name..."
        git -C "$target_dir" pull
    fi
done

# Install requirements in parallel (only if requirements.txt exists)
declare -a PIDS=()
declare -a NAMES=()

for repo in "${REPOS[@]}"; do
    folder_name=$(basename "$repo" .git)
    req_file="$CUSTOM_NODES_DIR/$folder_name/requirements.txt"

    if [ -f "$req_file" ]; then
        echo "🔧 Installing $folder_name packages..."
        pip install --no-cache-dir -r "$req_file" &
        PIDS+=($!)
        NAMES+=("$folder_name")
    fi
done

# Wait for pip installs and check results
FAILED=0
for i in "${!PIDS[@]}"; do
    wait "${PIDS[$i]}"
    if [ $? -eq 0 ]; then
        echo "✅ ${NAMES[$i]} install complete"
    else
        echo "❌ ${NAMES[$i]} install failed."
        FAILED=1
    fi
done

if [ $FAILED -ne 0 ]; then
    echo "⚠️  Some custom node installations failed. Continuing anyway..."
fi

# Keep checking until no aria2c processes are running
while pgrep -x "aria2c" > /dev/null; do
    echo "🔽 Model Downloads still in progress..."
    sleep 10  # Check every 10 seconds
done

echo "✅ All models downloaded successfully!"

echo "Updating default preview method..."
sed -i '/id: *'"'"'VHS.LatentPreview'"'"'/,/defaultValue:/s/defaultValue: false/defaultValue: true/' /ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite/web/js/VHS.core.js
CONFIG_PATH="/ComfyUI/user/default/ComfyUI-Manager"
CONFIG_FILE="$CONFIG_PATH/config.ini"

# Ensure the directory exists
mkdir -p "$CONFIG_PATH"

# Create the config file if it doesn't exist
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating config.ini..."
    cat <<EOL > "$CONFIG_FILE"
[default]
preview_method = auto
git_exe =
use_uv = False
channel_url = https://raw.githubusercontent.com/ltdrdata/ComfyUI-Manager/main
share_option = all
bypass_ssl = False
file_logging = True
component_policy = workflow
update_policy = stable-comfyui
windows_selector_event_loop_policy = False
model_download_by_agent = False
downgrade_blacklist =
security_level = normal
skip_migration_check = False
always_lazy_install = False
network_mode = public
db_mode = cache
EOL
else
    echo "config.ini already exists. Updating preview_method..."
    sed -i 's/^preview_method = .*/preview_method = auto/' "$CONFIG_FILE"
fi

# Wait for SageAttention build to complete
echo "Waiting for SageAttention build to complete..."
while ! [ -f /tmp/sage_build_done ]; do
    if ps -p $SAGE_PID > /dev/null 2>&1; then
        echo "⚙️  SageAttention build in progress, this may take up to 5 minutes."
        sleep 5
    else
        # Process finished but no completion marker - check if it failed
        if ! [ -f /tmp/sage_build_done ]; then
            echo "⚠️  SageAttention build process ended unexpectedly. Check logs at /tmp/sage_build.log"
            echo "Continuing with ComfyUI startup..."
            break
        fi
    fi
done

if [ -f /tmp/sage_build_done ]; then
    echo "✅ SageAttention build completed successfully!"
fi

URL="http://127.0.0.1:8188"

echo "▶️  Starting ComfyUI"
nohup python3 "/ComfyUI/main.py" --listen --use-sage-attention > "/comfyui_nohup.log" 2>&1 &