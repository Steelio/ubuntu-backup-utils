#!/bin/bash

# Configuration
BACKUP_DIR="/mnt/backup"
BACKUP_NAME="ubuntu_backup_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/server_backup.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

backup_items=(
    "/etc"                  # System configuration
    "/home"                 # User home directories
    "/var/www"             # Web server files
    "/var/log"             # System logs
    "/var/mail"            # Mail data
    "/opt"                 # Optional software
    "/root"                # Root user directory
    "/usr/local"           # Locally installed software
)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}Please run as root${NC}"
        exit 1
    fi
}

get_dir_size() {
    local dir=$1
    if [ -e "$dir" ]; then
        du -sh "$dir" 2>/dev/null
    else
        echo -e "${RED}Directory $dir does not exist${NC}"
    fi
}

list_backup_dirs() {
    echo -e "\n${BLUE}Directories to be backed up:${NC}"
    echo -e "${BLUE}==========================${NC}"
    
    local total_size=0
    
    printf "%-30s %-15s %-20s\n" "Directory" "Size" "Status"
    printf "%-30s %-15s %-20s\n" "---------" "----" "------"
    
    for item in "${backup_items[@]}"; do
        if [ -e "$item" ]; then
            size=$(du -sb "$item" 2>/dev/null | cut -f1)
            human_size=$(numfmt --to=iec-i --suffix=B --format="%.1f" $size)
            total_size=$((total_size + size))
            printf "%-30s %-15s %-20s\n" "$item" "$human_size" "${GREEN}Available${NC}"
        else
            printf "%-30s %-15s %-20s\n" "$item" "N/A" "${RED}Not Found${NC}"
        fi
    done
    
    echo -e "\n${BLUE}Total size of all available directories:${NC} $(numfmt --to=iec-i --suffix=B --format="%.1f" $total_size)"
}

check_disk_space() {
    mkdir -p "$BACKUP_DIR"
    
    local backup_mount=$(df -P "$BACKUP_DIR" | awk 'NR==2 {print $6}')
    local available_blocks=$(df -P "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    
    local available_space=$((available_blocks * 1024))
    local total_size=0
    
    for item in "${backup_items[@]}"; do
        if [ -e "$item" ]; then
            size=$(du -sb "$item" 2>/dev/null | cut -f1)
            total_size=$((total_size + size))
        fi
    done
    
    echo -e "\n${BLUE}Disk Space Analysis:${NC}"
    echo "Backup location: $BACKUP_DIR"
    echo "Mount point: $backup_mount"
    echo "Available space: $(numfmt --to=iec-i --suffix=B --format="%.1f" $available_space)"
    echo "Required space: $(numfmt --to=iec-i --suffix=B --format="%.1f" $total_size)"
    
    if [ -n "$available_space" ] && [ "$available_space" -gt 0 ]; then
        if [ "$available_space" -lt "$total_size" ]; then
            echo -e "${RED}Warning: Not enough space for backup!${NC}"
            echo "Need additional: $(numfmt --to=iec-i --suffix=B --format="%.1f" $((total_size - available_space)))"
            return 1
        else
            echo -e "${GREEN}Sufficient space available for backup.${NC}"
            echo "Extra space: $(numfmt --to=iec-i --suffix=B --format="%.1f" $((available_space - total_size)))"
            return 0
        fi
    else
        echo -e "${RED}Error: Could not determine available space!${NC}"
        return 1
    fi
}

perform_backup() {
    mkdir -p "$BACKUP_DIR"
    
    # Start logging
    exec 1> >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)
    
    echo "Starting backup at $(date)"

    TEMP_DIR=$(mktemp -d)
    log "Created temporary directory: $TEMP_DIR"
    
    # Database backup (if MySQL/MariaDB is installed)
    if command -v mysqldump &> /dev/null; then
        log "Backing up MySQL databases..."
        mkdir -p "$TEMP_DIR/databases"
        mysqldump --all-databases -u root > "$TEMP_DIR/databases/all_databases.sql" 2>/dev/null || log "MySQL backup failed"
    fi
    
    if command -v dpkg &> /dev/null; then
        log "Saving list of installed packages..."
        dpkg --get-selections > "$TEMP_DIR/installed_packages.txt"
    fi
    
    log "Saving system service status..."
    systemctl list-units --type=service --all > "$TEMP_DIR/service_status.txt"
    
    for item in "${backup_items[@]}"; do
        if [ -e "$item" ]; then
            log "Backing up $item..."
            rsync -az "$item" "$TEMP_DIR/" || log "Failed to backup $item"
        fi
    done
    
    log "Creating compressed archive..."
    tar -czf "$BACKUP_DIR/$BACKUP_NAME.tar.gz" -C "$TEMP_DIR" . || {
        log "Backup failed!"
        rm -rf "$TEMP_DIR"
        return 1
    }
    
    # Calculate backup size
    BACKUP_SIZE=$(du -h "$BACKUP_DIR/$BACKUP_NAME.tar.gz" | cut -f1)
    
    # Cleanup
    rm -rf "$TEMP_DIR"
    
    log "Backup completed successfully!"
    log "Backup location: $BACKUP_DIR/$BACKUP_NAME.tar.gz"
    log "Backup size: $BACKUP_SIZE"
    
    # Keep only last 5 backups
    cd "$BACKUP_DIR" || exit
    ls -t ubuntu_backup_*.tar.gz | tail -n +6 | xargs -r rm
    
    echo -e "${GREEN}Backup process completed at $(date)${NC}"
    return 0
}
list_existing_backups() {
    echo -e "\n${BLUE}Existing Backups:${NC}"
    echo -e "${BLUE}=================${NC}"
    
    if [ -d "$BACKUP_DIR" ]; then
        if ls "$BACKUP_DIR"/ubuntu_backup_*.tar.gz 1> /dev/null 2>&1; then
            printf "%-4s %-40s %-15s %-20s\n" "No." "Backup Name" "Size" "Date Created"
            printf "%-4s %-40s %-15s %-20s\n" "---" "-----------" "----" "------------"
            
            local i=1
            declare -g backup_files=()  # Global array to store backup files
            
            while IFS= read -r backup; do
                backup_files+=("$backup")
                name=$(basename "$backup")
                size=$(du -h "$backup" | cut -f1)
                date=$(stat -c %y "$backup" | cut -d. -f1)
                printf "%-4s %-40s %-15s %-20s\n" "[$i]" "$name" "$size" "$date"
                ((i++))
            done < <(ls -t "$BACKUP_DIR"/ubuntu_backup_*.tar.gz)
            
            return 0
        else
            echo "No backups found"
            return 1
        fi
    else
        echo "Backup directory does not exist"
        return 1
    fi
}
restore_backup() {
    echo -e "\n${BLUE}Backup Restoration Utility${NC}"
    echo -e "${BLUE}=======================${NC}"
    
    if ! list_existing_backups; then
        return 1
    fi
    
    local max_index=${#backup_files[@]}
    local selection
    
    while true; do
        read -p "Enter the number of the backup to restore [1-$max_index] (or 'q' to quit): " selection
        
        if [[ "$selection" == "q" ]]; then
            return 0
        elif ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$max_index" ]; then
            echo -e "${RED}Invalid selection. Please enter a number between 1 and $max_index${NC}"
        else
            break
        fi
    done
    
    local selected_backup="${backup_files[$((selection-1))]}"
    echo -e "\n${RED}Warning: This will restore the following backup:${NC}"
    echo "Backup file: $(basename "$selected_backup")"
    echo -e "${RED}This operation will overwrite existing files. Make sure you have a current backup before proceeding.${NC}"
    
    echo -e "\n${BLUE}Backup contents:${NC}"
    tar -tzf "$selected_backup" | grep -v "^.$" | head -n 10
    echo "..."
    
    echo -e "\n${BLUE}Checking space requirements...${NC}"
    local extracted_size=$(tar -tzf "$selected_backup" | tr -s ' ' | cut -d ' ' -f3 | awk '{total += $1} END {print total}')
    local available_space=$(df -B1 / | awk 'NR==2 {print $4}')
    
    echo "Required space: $(numfmt --to=iec-i --suffix=B --format="%.1f" $extracted_size)"
    echo "Available space: $(numfmt --to=iec-i --suffix=B --format="%.1f" $available_space)"
    
    if [ "$available_space" -lt "$extracted_size" ]; then
        echo -e "${RED}Error: Not enough space to restore backup!${NC}"
        return 1
    fi
    
    read -p "Do you want to continue with the restore? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Restore cancelled"
        return 0
    fi
    
    echo -e "\n${BLUE}Starting restore process...${NC}"
    
    local temp_dir=$(mktemp -d)
    
    echo "Extracting backup..."
    if ! tar -xzf "$selected_backup" -C "$temp_dir"; then
        echo -e "${RED}Error: Failed to extract backup!${NC}"
        rm -rf "$temp_dir"
        return 1
    fi
    
    echo "Restoring files..."
    for dir in $(ls "$temp_dir"); do
        if [ -d "$temp_dir/$dir" ]; then
            echo "Restoring /$dir..."
            rsync -aAX --delete "$temp_dir/$dir/" "/$dir/"
        fi
    done
    
    if [ -f "$temp_dir/databases/all_databases.sql" ]; then
        echo "Restoring databases..."
        if command -v mysql &> /dev/null; then
            mysql -u root < "$temp_dir/databases/all_databases.sql"
        else
            echo -e "${YELLOW}MySQL not installed, skipping database restore${NC}"
        fi
    fi
    
    rm -rf "$temp_dir"
    
    echo -e "${GREEN}Restore completed successfully!${NC}"
    echo -e "${YELLOW}Note: Some services may need to be restarted for changes to take effect.${NC}"
    
    read -p "Would you like to restart the system now? (yes/no): " restart
    if [[ "$restart" == "yes" ]]; then
        echo "System will restart in 10 seconds..."
        sleep 10
        reboot
    fi
}

verify_backup() {
    local backup_file="$1"
    echo -e "\n${BLUE}Verifying backup integrity...${NC}"
    
    if [ ! -r "$backup_file" ]; then
        echo -e "${RED}Error: Backup file is not readable or doesn't exist!${NC}"
        return 1
    fi
    
    if ! tar -tzf "$backup_file" >/dev/null 2>&1; then
        echo -e "${RED}Error: Backup file is corrupted or not a valid tar.gz archive!${NC}"
        return 1
    fi
    
    local checksum_file="${backup_file}.sha256"
    if [ -f "$checksum_file" ]; then
        echo "Verifying checksum..."
        if ! sha256sum -c "$checksum_file" >/dev/null 2>&1; then
            echo -e "${RED}Error: Backup file checksum verification failed!${NC}"
            return 1
        fi
        echo -e "${GREEN}Checksum verification passed.${NC}"
    else
        echo -e "${YELLOW}Warning: No checksum file found. Creating one now...${NC}"
        sha256sum "$backup_file" > "$checksum_file"
    fi
    
    echo -e "${GREEN}Backup integrity verification passed.${NC}"
    return 0
}

show_menu() {
    while true; do
        echo -e "\n${BLUE}Ubuntu Server Backup Utility${NC}"
        echo -e "${BLUE}=========================${NC}"
        echo "1. List directories to be backed up"
        echo "2. Check disk space"
        echo "3. List existing backups"
        echo "4. Start backup"
        echo "5. Restore backup <- USE AT YOUR OWN RISK!"
        echo "6. Exit"
        read -p "Select an option (1-6): " choice
        
        case $choice in
            1)
                list_backup_dirs
                ;;
            2)
                check_disk_space
                ;;
            3)
                list_existing_backups
                ;;
            4)
                echo -e "\n${BLUE}Starting backup process...${NC}"
                check_disk_space
                if [ $? -eq 0 ]; then
                    read -p "Continue with backup? (y/n): " confirm
                    if [ "$confirm" = "y" ]; then
                        perform_backup
                    fi
                fi
                ;;
            5)
                restore_backup
                ;;
            6)
                echo -e "${GREEN}Exiting...${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                ;;
        esac
    done
}


# Main execution
check_root
show_menu
