#!/bin/bash

set -eo pipefail

# --- Configuration ---
CONFIG_FILE="backup_config.json"
DEFAULT_BACKUP_DIR_HARDCODED="$(pwd)/docker_volume_backups" # Fallback if config is missing
DEFAULT_MAX_BACKUPS_HARDCODED=5                         # Fallback if config is missing
TIMESTAMP_FORMAT="%Y%m%d_%H%M%S"                      # Format for backup timestamps

# --- Global Config Variables ---
declare CONFIG_BACKUP_DIR=""
declare CONFIG_DEFAULT_MAX_BACKUPS=""
declare -A CONFIG_VOLUMES # Associative array: CONFIG_VOLUMES[volume_name]=max_backups

# --- Dependency Check ---
check_jq() {
    if ! command -v jq &> /dev/null; then
        echo "ERROR: jq is not installed. Please install jq to manage the configuration file."
        echo "(e.g., sudo apt update && sudo apt install jq)" >&2
        exit 1
    fi
}

# --- Helper Functions ---

# Basic logging
log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1"
}

# Get a list of volumes currently used by running containers
list_running_volumes() {
    docker ps --format '{{.ID}}' | xargs -I {} docker inspect {} --format '{{range .Mounts}}{{.Name}} {{end}}' | tr ' ' '\n' | sort -u | grep -v '^$' || true
}

# Get backup directory (prompt if interactive, else use default/config)
get_backup_dir() {
    local backup_dir_var="$1" # Variable name to store the result
    local interactive_mode="$2"
    # Use loaded config dir as the default, then hardcoded
    local default_dir="${CONFIG_BACKUP_DIR:-$DEFAULT_BACKUP_DIR_HARDCODED}"

    # Only prompt in interactive *backup* mode, not restore or config
    if [[ "$interactive_mode" == "true" ]] && [[ "$ACTION" == "backup" ]]; then
        if [[ "$interactive_mode" == "true" ]]; then
            read -p "Enter backup directory [$default_dir]: " entered_dir
            eval "$backup_dir_var=\"${entered_dir:-$default_dir}\""
        else
            eval "$backup_dir_var=\"$default_dir\""
        fi
    fi

    # Create backup directory if it doesn't exist
    mkdir -p "${!backup_dir_var}" || { log "ERROR: Failed to create backup directory '${!backup_dir_var}'. Check permissions."; exit 1; }
    log "Using backup directory: ${!backup_dir_var}"
}

# Helper function to get the specific path for a volume's backups
get_volume_backup_path() {
    local main_backup_dir="$1"
    local volume_name="$2"
    # Basic sanitization for volume name to avoid issues with path traversal or weird chars
    # Replace / with _ and remove any characters not alphanumeric, underscore, or hyphen
    local sanitized_volume_name=$(echo "$volume_name" | sed 's|/|_|g' | tr -cd '[:alnum:]_-')
    if [[ -z "$sanitized_volume_name" ]]; then
        log "ERROR: Could not generate a valid directory name for volume '$volume_name'"
        return 1 # Indicate error
    fi
    echo "${main_backup_dir}/${sanitized_volume_name}"
}

# Helper function to select multiple volumes interactively
select_multiple_volumes() {
    local available_volumes_ref=$1 # Reference to the array of available volumes
    local selected_volumes_ref=$2 # Reference to the array to store selected volumes

    declare -n _available_volumes="$available_volumes_ref"
    declare -n _selected_volumes="$selected_volumes_ref"
    _selected_volumes=() # Clear previous selection

    if [ ${#_available_volumes[@]} -eq 0 ]; then
        log "No volumes available for selection."
        return 1
    fi

    log "Available running volumes:"
    local i=1
    for vol in "${_available_volumes[@]}"; do
        echo "  $i) $vol"
        i=$((i + 1))
    done
    echo "  A) All"
    echo "  Q) Quit"

    while true; do
        read -p "Select volumes to backup (e.g., 1,3,5 or A, Q): " choice
        choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]') # Convert to lowercase

        _selected_volumes=() # Reset selection for each input attempt

        if [[ "$choice" == "q" ]]; then
            log "Selection cancelled."
            return 1 # Indicate quit
        elif [[ "$choice" == "a" ]]; then
            _selected_volumes=("${_available_volumes[@]}")
            log "Selected: All volumes."
            return 0 # Indicate success
        else
            # Process comma-separated numbers
            local valid_selection=true
            IFS=',' read -ra selections <<< "$choice"
            for sel in "${selections[@]}"; do
                # Trim whitespace
                sel=$(echo "$sel" | sed 's/^[ \t]*//;s/[ \t]*$//')
                if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#_available_volumes[@]} ]; then
                    local index=$((sel - 1))
                    # Avoid duplicates if user enters same number twice
                    if [[ ! " ${_selected_volumes[@]} " =~ " ${_available_volumes[$index]} " ]]; then
                         _selected_volumes+=("${_available_volumes[$index]}")
                    fi
                else
                    echo "Invalid selection: '$sel'. Please enter numbers from the list, 'A' for All, or 'Q' to Quit."
                    valid_selection=false
                    break
                fi
            done

            if [[ "$valid_selection" == "true" ]] && [ ${#_selected_volumes[@]} -gt 0 ]; then
                log "Selected volumes:"
                for vol in "${_selected_volumes[@]}"; do
                    echo " - $vol"
                done
                return 0 # Indicate success
            elif [[ "$valid_selection" == "true" ]] && [ ${#_selected_volumes[@]} -eq 0 ]; then
                 # Handles empty input or just commas
                 echo "No volumes selected. Please enter numbers, 'A', or 'Q'."
            fi
            # Loop again if invalid or empty selection
        fi
    done
}

# Backup a single volume
backup_volume() {
    local volume_name="$1"
    local backup_dir="$2"
    local timestamp=$(date +"$TIMESTAMP_FORMAT")
    local backup_filename="${volume_name}_${timestamp}.tar.gz"
    local volume_backup_dir=$(get_volume_backup_path "$backup_dir" "$volume_name")
    if [[ $? -ne 0 ]]; then return 1; fi # Error handled in get_volume_backup_path

    # Ensure the volume-specific directory exists
    mkdir -p "$volume_backup_dir" || { log "ERROR: Failed to create volume backup directory '$volume_backup_dir'. Check permissions."; return 1; }

    local backup_path="${volume_backup_dir}/${backup_filename}"
    # Use date + random instead of uuidgen for portability
    local temp_container_name="volume_backup_helper_$(date +%s%N)_$RANDOM"

    log "Starting backup for volume: $volume_name into $volume_backup_dir"
    docker run --rm --name "$temp_container_name" \
        -v "${volume_name}:/volume_data:ro" \
        -v "${volume_backup_dir}:/backup_target" \
        alpine \
        tar -czf "/backup_target/${backup_filename}" -C /volume_data .

    if [[ $? -eq 0 ]]; then
        log "Successfully backed up volume '$volume_name' to '$backup_path'"
    else
        log "ERROR: Failed to back up volume '$volume_name'."
        # Clean up potentially incomplete backup file
        rm -f "$backup_path"
        return 1 # Indicate failure
    fi
    return 0 # Indicate success
}

# Rotate backups, keeping only the newest N
rotate_backups() {
    local volume_name="$1"
    local backup_dir="$2"
    local max_to_keep="$3"

    local volume_backup_dir=$(get_volume_backup_path "$backup_dir" "$volume_name")
    if [[ $? -ne 0 ]]; then return 1; fi # Error handled in get_volume_backup_path

    # Check if the directory exists before attempting rotation
    if [[ ! -d "$volume_backup_dir" ]]; then
        log "Backup directory '$volume_backup_dir' for volume '$volume_name' not found. Skipping rotation."
        return 0
    fi

    # Validate max_to_keep
    if ! [[ "$max_to_keep" =~ ^[0-9]+$ ]] || [[ "$max_to_keep" -lt 1 ]]; then
        log "Warning: Invalid max_backups value '$max_to_keep' for volume '$volume_name'. Using default 1."
        max_to_keep=1
    fi

    log "Rotating backups for volume: $volume_name in $volume_backup_dir (keeping $max_to_keep)"
    # List backups for the specific volume within its directory
    ls -1t "${volume_backup_dir}/${volume_name}_"*.tar.gz 2>/dev/null | tail -n +$(($max_to_keep + 1)) | while read -r old_backup; do
        log "Deleting old backup: $old_backup"
        rm "$old_backup"
    done
}

# List available backups for a volume
list_backups() {
    local volume_name="$1"
    local backup_dir="$2"
    local volume_backup_dir=$(get_volume_backup_path "$backup_dir" "$volume_name")
    if [[ $? -ne 0 ]]; then return 1; fi # Error handled in get_volume_backup_path

    if [[ ! -d "$volume_backup_dir" ]]; then
         log "Backup directory '$volume_backup_dir' for volume '$volume_name' not found."
         return 1
    fi

    log "Available backups for volume '$volume_name' in '$volume_backup_dir':"
    find "$volume_backup_dir" -maxdepth 1 -name "${volume_name}_*.tar.gz" -printf "%f\n" | sort
}

# Restore a volume from a backup file
restore_volume() {
    local volume_name="$1"
    local backup_filename="$2"
    local volume_backup_dir="$3" # Note: This is now the *volume-specific* directory
    local backup_path="${volume_backup_dir}/${backup_filename}"
    # Use date + random instead of uuidgen for portability
    local temp_container_name="volume_restore_helper_$(date +%s%N)_$RANDOM"

    if [[ ! -f "$backup_path" ]]; then
        log "ERROR: Backup file '$backup_path' not found."
        return 1
    fi

    log "Starting restore for volume '$volume_name' from '$backup_filename'"

    # 1. Check if volume exists
    if docker volume inspect "$volume_name" >/dev/null 2>&1; then
        log "Volume '$volume_name' exists."
        # 2. Find containers using the volume
        local containers_using_volume=$(docker ps -a --filter volume="$volume_name" --format '{{.Names}}')
        if [[ -n "$containers_using_volume" ]]; then
            log "The following containers use volume '$volume_name':"
            echo "$containers_using_volume"
            read -p "Stop these containers and remove the volume to restore? (y/N): " confirm_stop
            if [[ ! "$confirm_stop" =~ ^[Yy]$ ]]; then
                log "Restore cancelled by user."
                return 1
            fi
            log "Stopping containers..."
            echo "$containers_using_volume" | xargs -I {} docker stop {}
            log "Removing existing volume '$volume_name'..."
            docker volume rm "$volume_name"
        else
             read -p "Volume '$volume_name' exists but is not currently used by any container. Remove and recreate it for restore? (y/N): " confirm_remove
             if [[ ! "$confirm_remove" =~ ^[Yy]$ ]]; then
                 log "Restore cancelled by user."
                 return 1
             fi
             log "Removing existing volume '$volume_name'..."
             docker volume rm "$volume_name"
        fi
    else
        log "Volume '$volume_name' does not exist. It will be created."
    fi

    # 3. Create the volume (it might have specific drivers/options, but we create a default one here)
    #    For advanced cases, manual creation before restore might be needed.
    log "Creating volume '$volume_name'..."
    docker volume create "$volume_name" >/dev/null

    # 4. Restore data using a temporary container
    log "Restoring data..."
    docker run --rm --name "$temp_container_name" \
        -v "${volume_name}:/volume_data" \
        -v "${volume_backup_dir}:/backup_source:ro" \
        alpine \
        tar -xzf "/backup_source/${backup_filename}" -C /volume_data

    if [[ $? -eq 0 ]]; then
        log "Successfully restored volume '$volume_name' from '$backup_path'"
        # 5. Restart previously stopped containers if any
        if [[ -n "$containers_using_volume" ]]; then
             log "Restarting previously stopped containers..."
             echo "$containers_using_volume" | xargs -I {} docker start {}
        fi
    else
        log "ERROR: Failed to restore volume '$volume_name'."
        # Consider cleanup? Maybe leave the volume for inspection.
        return 1
    fi
    return 0
}

# Load configuration from JSON file
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "Configuration file '$CONFIG_FILE' not found. Using hardcoded defaults."
        CONFIG_BACKUP_DIR="$DEFAULT_BACKUP_DIR_HARDCODED"
        CONFIG_DEFAULT_MAX_BACKUPS="$DEFAULT_MAX_BACKUPS_HARDCODED"
        CONFIG_VOLUMES=()
        return
    fi

    log "Loading configuration from '$CONFIG_FILE'"
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        log "ERROR: Configuration file '$CONFIG_FILE' contains invalid JSON."
        exit 1
    fi

    CONFIG_BACKUP_DIR=$(jq -r '.backup_directory // empty' "$CONFIG_FILE")
    CONFIG_DEFAULT_MAX_BACKUPS=$(jq -r '.default_max_backups // empty' "$CONFIG_FILE")

    # Fallbacks if values are null or empty in JSON
    [[ -z "$CONFIG_BACKUP_DIR" ]] && CONFIG_BACKUP_DIR="$DEFAULT_BACKUP_DIR_HARDCODED"
    [[ -z "$CONFIG_DEFAULT_MAX_BACKUPS" ]] && CONFIG_DEFAULT_MAX_BACKUPS="$DEFAULT_MAX_BACKUPS_HARDCODED"

    CONFIG_VOLUMES=()
    while IFS='=' read -r key value; do
        # Ensure value is treated as a number, default if invalid/missing
        if [[ "$value" =~ ^[0-9]+$ ]]; then
            CONFIG_VOLUMES["$key"]=$value
        else
             CONFIG_VOLUMES["$key"]=$CONFIG_DEFAULT_MAX_BACKUPS
        fi
    done < <(jq -r '.volumes[] | "\(.name)=\(.max_backups // "null")"' "$CONFIG_FILE" 2>/dev/null || true)

    log "Config loaded: Backup Dir='$CONFIG_BACKUP_DIR', Default Max='$CONFIG_DEFAULT_MAX_BACKUPS', Volumes=${!CONFIG_VOLUMES[@]}"
}

# Interactively generate configuration
generate_config() {
    log "--- Configuration Generation --- (Requires jq)"
    check_jq

    local current_dir=${CONFIG_BACKUP_DIR:-$DEFAULT_BACKUP_DIR_HARDCODED}
    local current_default_max=${CONFIG_DEFAULT_MAX_BACKUPS:-$DEFAULT_MAX_BACKUPS_HARDCODED}

    read -p "Enter backup directory [$current_dir]: " new_backup_dir
    new_backup_dir=${new_backup_dir:-$current_dir}

    local new_default_max
    while true; do
        read -p "Enter default number of backups to keep per volume [$current_default_max]: " new_default_max
        new_default_max=${new_default_max:-$current_default_max}
        if [[ "$new_default_max" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            echo "Invalid number. Please enter a positive integer."
        fi
    done

    log "Fetching all Docker volumes..."
    # Use docker volume ls --format '{{.Name}}' to get all volumes
    all_volumes=($(docker volume ls --format '{{.Name}}'))
    if [ ${#all_volumes[@]} -eq 0 ]; then
        log "No Docker volumes found on the system."
        # Still proceed to save basic config if desired
    fi

    local configured_volumes=()
    local temp_max_backups=()
    if [ ${#all_volumes[@]} -gt 0 ]; then
        log "Select volumes to include in the configuration:"
        local i=1
        for vol in "${all_volumes[@]}"; do
            local current_setting="(default: $new_default_max)"
            if [[ -v CONFIG_VOLUMES["$vol"] ]]; then
                 current_setting="(current: ${CONFIG_VOLUMES[$vol]})"
            fi
            echo "  $i) $vol $current_setting"
            i=$((i + 1))
        done
        echo "  A) All"
        echo "  N) None (clear existing)"
        echo "  Q) Quit (discard changes)"

        while true; do
            read -p "Select volumes (e.g., 1,3,5 or A, N, Q): " choice
            choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]')
            configured_volumes=()
            temp_max_backups=()
            local valid_selection=true

            if [[ "$choice" == "q" ]]; then
                log "Configuration cancelled."
                exit 0
            elif [[ "$choice" == "n" ]]; then
                log "Selected: None (will clear volume list in config)."
                break
            elif [[ "$choice" == "a" ]]; then
                configured_volumes=("${all_volumes[@]}")
                log "Selected: All volumes."
                break
            else
                IFS=',' read -ra selections <<< "$choice"
                for sel in "${selections[@]}"; do
                    sel=$(echo "$sel" | sed 's/^[ \t]*//;s/[ \t]*$//')
                    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#all_volumes[@]} ]; then
                        local index=$((sel - 1))
                        if [[ ! " ${configured_volumes[@]} " =~ " ${all_volumes[$index]} " ]]; then
                            configured_volumes+=("${all_volumes[$index]}")
                        fi
                    else
                        echo "Invalid selection: '$sel'. Please enter numbers, 'A', 'N', or 'Q'."
                        valid_selection=false
                        break
                    fi
                done
                if [[ "$valid_selection" == "true" ]] && [ ${#configured_volumes[@]} -gt 0 ]; then
                    log "Selected volumes: ${configured_volumes[*]}"
                    break
                elif [[ "$valid_selection" == "true" ]]; then
                     echo "No volumes selected. Please enter numbers, 'A', 'N', or 'Q'."
                fi
            fi
        done
    fi

    # Ask for max_backups for each selected volume
    if [ ${#configured_volumes[@]} -gt 0 ]; then
        log "Configure max backups for selected volumes (leave blank to use default: $new_default_max):"
        for vol in "${configured_volumes[@]}"; do
            local current_vol_max="$new_default_max"
             # Suggest previous value if it existed
             if [[ -v CONFIG_VOLUMES["$vol"] ]]; then
                 current_vol_max=${CONFIG_VOLUMES[$vol]}
             fi

            local specific_max
            while true; do
                read -p " - Max backups for '$vol' [$current_vol_max]: " specific_max
                specific_max=${specific_max:-$current_vol_max}
                 if [[ "$specific_max" =~ ^[1-9][0-9]*$ ]]; then
                     temp_max_backups+=("$specific_max")
                     break
                 else
                      echo "Invalid number. Please enter a positive integer."
                 fi
            done
        done
    fi

    # Build JSON
    log "--- Proposed Configuration ---"
    echo "Backup Directory: $new_backup_dir"
    echo "Default Max Backups: $new_default_max"
    echo "Volumes to Manage:"
    local json_volumes="[]"
    if [ ${#configured_volumes[@]} -gt 0 ]; then
        local first=true
        json_volumes="["
        for i in "${!configured_volumes[@]}"; do
            local vol_name="${configured_volumes[$i]}"
            local vol_max="${temp_max_backups[$i]}"
            echo " - Name: $vol_name, Max Backups: $vol_max"
            if [[ $first == false ]]; then json_volumes+=","; fi
            # Use jq to safely escape the volume name for JSON
            local escaped_name=$(jq -n --arg name "$vol_name" '$name')
            json_volumes+=$(printf '{"name": %s, "max_backups": %s}' "$escaped_name" "$vol_max")
            first=false
        done
        json_volumes+="]"
    else
        echo " (None)"
    fi
    echo "-----------------------------"

    read -p "Save this configuration to '$CONFIG_FILE'? (y/N): " confirm_save
    if [[ "$confirm_save" =~ ^[Yy]$ ]]; then
        local config_json
        config_json=$(jq -n \
            --arg dir "$new_backup_dir" \
            --argjson max "$new_default_max" \
            --argjson vols "$json_volumes" \
            '{backup_directory: $dir, default_max_backups: $max, volumes: $vols}')

        echo "$config_json" > "$CONFIG_FILE"
        if [[ $? -eq 0 ]]; then
            log "Configuration successfully saved to '$CONFIG_FILE'."
            # Reload config into memory for the current run if needed elsewhere
            load_config
        else
            log "ERROR: Failed to write configuration to '$CONFIG_FILE'."
            exit 1
        fi
    else
        log "Configuration not saved."
    fi
    exit 0
}

# --- Main Logic ---

# Default mode is silent
INTERACTIVE="false"
ACTION="backup" # Default action
MODE="silent"   # Default mode

# Parse arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -i|--interactive)
        MODE="interactive"
        shift # past argument
        ;;
        -r|--restore)
        ACTION="restore"
        MODE="interactive" # Restore is always interactive for safety
        shift # past argument
        ;;
        -c|--configure)
        ACTION="configure"
        MODE="interactive" # Configure is always interactive
        shift
        ;;
        -h|--help)
        echo "Usage: $0 [-i] [-r] [-c] [-h]"
        echo "  -i, --interactive  Run interactive backup mode (select running volumes)."
        echo "  -r, --restore      Enter interactive restore mode."
        echo "  -c, --configure    Interactively configure backup settings ('$CONFIG_FILE')."
        echo "  -h, --help         Show this help message."
        echo
        echo "Default (no flags): Run silent backup mode (backs up volumes from '$CONFIG_FILE')."
        exit 0
        ;;
        *)    # unknown option
        log "Unknown option: $1"
        exit 1
        ;;
    esac
done

# --- Execution ---

check_jq # Check for jq before potentially needing it
load_config # Load config early

if [[ "$ACTION" == "configure" ]]; then
    generate_config # Function handles its own exit
fi

# Determine backup dir (interactive backup might override later)
BACKUP_DIR="$CONFIG_BACKUP_DIR"
# Create backup directory if it doesn't exist (needed for silent mode)
mkdir -p "$BACKUP_DIR" || { log "ERROR: Failed to create backup directory '$BACKUP_DIR'. Check permissions."; exit 1; }

if [[ "$ACTION" == "backup" ]]; then
    if [[ "$MODE" == "interactive" ]]; then
        log "--- Interactive Backup Mode ---"
        # Re-evaluate backup dir interactively if needed
        get_backup_dir BACKUP_DIR "true"

        running_volumes=($(list_running_volumes))

        if [ ${#running_volumes[@]} -eq 0 ]; then
            log "No running volumes found to back up."
            exit 0
        fi

        selected_volumes=()
        if ! select_multiple_volumes running_volumes selected_volumes; then
             log "Exiting backup."
             exit 0 # User chose to Quit
        fi

        if [ ${#selected_volumes[@]} -eq 0 ]; then
            log "No volumes were selected for backup."
            exit 0
        fi

        # Confirmation step
        log "The following volumes will be backed up:"
        for vol in "${selected_volumes[@]}"; do
            echo " - $vol"
        done
        read -p "Proceed with backup? (y/N): " confirm_backup
        if [[ ! "$confirm_backup" =~ ^[Yy]$ ]]; then
            log "Backup cancelled by user."
            exit 0
        fi

        backup_failed=0
        for vol in "${selected_volumes[@]}"; do
            # Determine max backups: check config for volume, then config default
            local max_backups=${CONFIG_VOLUMES[$vol]:-$CONFIG_DEFAULT_MAX_BACKUPS}
            backup_volume "$vol" "$BACKUP_DIR"
            if [[ $? -ne 0 ]]; then
                backup_failed=1
            else
                rotate_backups "$vol" "$BACKUP_DIR" "$max_backups"
            fi
        done

        if [[ $backup_failed -ne 0 ]]; then
             log "One or more volume backups failed."
             exit 1
        fi
        log "Backup process completed."

        exit 0
    else # Silent mode
        log "--- Silent Backup Mode (using $CONFIG_FILE) ---"

        if [ ${#CONFIG_VOLUMES[@]} -eq 0 ]; then
            log "No volumes configured in '$CONFIG_FILE'. Nothing to back up."
            exit 0
        fi

        log "Checking configured volumes: ${!CONFIG_VOLUMES[*]}"
        backup_failed=0
        volumes_backed_up=0
        for vol in "${!CONFIG_VOLUMES[@]}"; do
            # Check if volume actually exists before backup
            if ! docker volume inspect "$vol" >/dev/null 2>&1; then
                log "Warning: Configured volume '$vol' not found. Skipping."
                continue
            fi

            max_backups=${CONFIG_VOLUMES[$vol]} # Already resolved during load_config
            log "Processing backup for configured volume: $vol (max_backups: $max_backups)"
            backup_volume "$vol" "$BACKUP_DIR"
            if [[ $? -ne 0 ]]; then
                backup_failed=1
            else
                 volumes_backed_up=$((volumes_backed_up + 1))
                 rotate_backups "$vol" "$BACKUP_DIR" "$max_backups"
            fi
        done

        if [[ $volumes_backed_up -eq 0 ]] && [[ $backup_failed -eq 0 ]]; then
             log "No existing volumes found matching the configuration. Backup finished."
        elif [[ $backup_failed -ne 0 ]]; then
             log "One or more volume backups failed."
             exit 1
        fi
        log "Backup process completed."
        exit 0
    fi
fi

# --- Restore Logic ---
# Restore now uses the BACKUP_DIR determined earlier from config/default
if [[ "$ACTION" == "restore" ]]; then
    log "--- Interactive Restore Mode (using backup dir: $BACKUP_DIR) ---"

    # Get all potential volumes by listing subdirectories in the main backup directory
    available_volume_names=()
    # Use find to list directories, handle potential errors, get basename, sort
    while IFS= read -r dir_path; do
         # Extract original volume name if possible (assuming dir name matches sanitized name)
         # This is a bit heuristic, might need adjustment if sanitization is complex
         local potential_name=$(basename "$dir_path")
         # Maybe store original name alongside sanitized in config later? For now, use dir name.
        available_volume_names+=("$potential_name")
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

    if [ ${#available_volume_names[@]} -eq 0 ]; then
        log "No volume backup subdirectories found in '$BACKUP_DIR'."
        exit 1
    fi

    log "Select the volume you want to restore:"
    select volume_to_restore in "${available_volume_names[@]}" "Quit"; do
         if [[ "$volume_to_restore" == "Quit" ]]; then
            log "Exiting."
            exit 0
        elif [[ -n "$volume_to_restore" ]]; then
            log "Selected volume: $volume_to_restore"
            break
        else
            echo "Invalid choice. Please select a number."
        fi
    done

    # Determine the specific directory for the chosen volume
    # Use the selected name (which should be the sanitized directory name)
    local volume_to_restore_dir=$(get_volume_backup_path "$BACKUP_DIR" "$volume_to_restore")
    if [[ $? -ne 0 ]]; then exit 1; fi # Error handled in get_volume_backup_path
    if [[ ! -d "$volume_to_restore_dir" ]]; then
        log "ERROR: Selected volume directory '$volume_to_restore_dir' does not exist."
        exit 1
    fi

    # List backups within the volume-specific directory
    # Note: The backup filename uses the ORIGINAL volume name, but we search using the DIRECTORY name ($volume_to_restore)
    # We should use the directory name variable, not the original volume name variable here
    available_backups=($(find "$volume_to_restore_dir" -maxdepth 1 -name "${volume_to_restore}_*.tar.gz" -printf "%f\\n" 2>/dev/null | sort -r)) # Sort descending, newest first

    if [ ${#available_backups[@]} -eq 0 ]; then
        log "No backups found for volume '$volume_to_restore' in '$volume_to_restore_dir'."
        # This should theoretically not happen if the volume name was derived from existing files, but check anyway.
        exit 1
    fi

    log "Select the backup file to restore:"
    select backup_file_choice in "${available_backups[@]}" "Cancel"; do
         if [[ "$backup_file_choice" == "Cancel" ]]; then
            log "Restore cancelled."
            exit 0
        elif [[ -n "$backup_file_choice" ]]; then
            log "Selected backup file: $backup_file_choice"
            # Pass the volume-specific directory to restore_volume
            # The volume name itself should still be the original name for docker commands
            # We need to map the selected directory name back to the *original* docker volume name if sanitization occurred.
            # For simplicity now, assume the directory name IS the volume name docker knows.
            # A more robust solution might involve reading the config file again here or storing mapping.
            restore_volume "$volume_to_restore" "$backup_file_choice" "$volume_to_restore_dir"
            break
        else
            echo "Invalid choice. Please select a number."
        fi
    done

    log "Restore process completed."
    exit 0
fi

exit 0 