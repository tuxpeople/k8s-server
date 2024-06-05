#!//usr/bin/bash
# based on https://github.com/mikenye/docker-minecraft_bedrock_server/blob/main/rootfs/usr/local/bin/run_backup

# bonus features on, needed to find the Minecraft server PID
shopt -s extglob

# assure this is a Bedrock image
if [ -f /opt/bedrock-entry.sh ] ; then
    SERVER_TYPE="bedrock_server"
else
    echo "Currently only Bedrock is supported"
    exit 1
fi

# Set defaults if not given via ENV vars
[ -z "${BACKUP_FOLDER}" ] && BACKUP_FOLDER="/backup/minecraft_backup"
[ -z "${BACKUP_NAME}" ] && BACKUP_NAME="$(hostname)"

# Set some variables
DATA_DIR="/data"
SERVER_PID=$(echo `grep -l ${SERVER_TYPE} /proc/+([0-9])/cmdline` | cut -d'/' -f3)
BACKUP_DATETIME=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${BACKUP_FOLDER}/${BACKUP_NAME:-$(hostname)}"

# Some checks
[ -z "${SERVER_PID}" ] && exit 1
[ -z "${BACKUP_DIR}" ] && exit 1

sendcommand(){
    echo "$@" > /proc/${SERVER_PID}/fd/0
    if [ $? -eq 0 ]; then
        echo "Successfully sent command $@ to server"
    else
        echo "Sending command $@ to server failed."
    fi
}

# Ready, steady, go!
echo "Starting with the backup"

# Cleanup old temp files
rm -f /tmp/mc-backup.*

# create temporary file for server output
TMPFILE=$(mktemp /tmp/mc-backup.XXXXXX)

# Write the stdout of the pocess into the temporary file
# Start it as background process
cat /proc/${SERVER_PID}/fd/1 > ${TMPFILE} || exit 1 &

# Save cat PID and all childs, to kill it later
# Kudos: https://unix.stackexchange.com/a/124131
pid=$!
CAT_PID=$(grep -l "PPid.*$$" /proc/*/status | grep -o "[0-9]*"
    for PROC in $(cat /proc/$pid/task/*/children); do
        CAT_PID="$PROC $CAT_PID $(cat /proc/$PROC/task/*/children)"
    done
    printf '%s ' $CAT_PID)

# Start backup with performing a save resume in case of previously failed backup
sendcommand save resume || exit 1

# Little break, just in case
sleep 5

# Trigger a backup by writing save hold into server's stdin
echo "Placing server into 'save hold'..."
sendcommand save hold  || exit 1

# Continously wait for backup to be ready using save query every 2 seconds and read the console's reaction
echo "Repeatedly querying the server to see if the files are ready for backup..."
EXITCODE=1
while [ "${EXITCODE}" -ne "0" ]; do
    sendcommand save query || exit 1
    grep "Data saved. Files are now ready to be copied." ${TMPFILE} > /dev/null 2>&1
    EXITCODE=$?
    sleep 2
done

echo "Server is now in 'save hold', performing backup..."

# Little break, just in case
sleep 2

# Get files needed for backup
FILES_TO_BACKUP=$(grep -a -A 1 "Data saved. Files are now ready to be copied." ${TMPFILE} | tail -1 | cut -d "]" -f 2- | sed 's/^ *//g')

# Kill background process to listen to the stdout of the server, as we do not longer need it
kill $CAT_PID >/dev/null 2>&1

# delete temp file
rm ${TMPFILE}

# Set inter-field separator
IFS=','

# Prepare array
read -ra BACKUP_LIST <<< "$FILES_TO_BACKUP"

# checks
[ -z "${BACKUP_LIST}" ] && exit 1

# Loop through the list of files
for i in "${BACKUP_LIST[@]}"; do

    i=$(echo "$i" | sed 's/^ *//g' | sed 's/\r//g')

    # For each entry given, get the path, file and offset
    WORLD_DIR=$(echo "$i" | cut -d '/' -f 1)
    WORLD_FILE=$(basename "$(echo "$i" | cut -d ':' -f 1)")
    WORLD_FILE_OFFSET=$(echo "$i" | cut -d ':' -f 2)

    # Create backup directory
    BACKUP_DESTINATION="${BACKUP_DIR}/${WORLD_DIR}/${BACKUP_DATETIME}"
    mkdir -p "${BACKUP_DESTINATION}"

    # Copy specified backup files into backup dir & truncate files to specified offset
    cd "${DATA_DIR}/worlds/${WORLD_DIR}" || exit 1
    find . \
        -type f \
        -name "${WORLD_FILE}" \
        -print0 | while read -r -d $'\0' file
    do
        # shellcheck disable=SC2001
        file=$(echo "${file}" | sed "s|^\./||")
        mkdir -p "$(dirname "${BACKUP_DESTINATION}/${file}")"
        cp "./${file}" "${BACKUP_DESTINATION}/${file}"
        truncate -s "$WORLD_FILE_OFFSET" "${BACKUP_DESTINATION}/${file}"
    done

    # Also copy settings, whitelist and permissions for this point in time
    # cp "${DATA_DIR}/server.properties" "${BACKUP_DESTINATION}/server.properties"
    # cp "${DATA_DIR}/whitelist.json" "${BACKUP_DESTINATION}/whitelist.json"
    # cp "${DATA_DIR}/permissions.json" "${BACKUP_DESTINATION}/permissions.json"

done

# Release system from backup
echo "Releasing server from 'save hold'..."
sendcommand save resume || exit 1

# Compress backup
echo "Compressing backup..."
cd "${BACKUP_DIR}/${WORLD_DIR}" || exit 1
tar -C "${BACKUP_DATETIME}" -czvf "${BACKUP_DATETIME}.tar.gz" .  | stdbuf -o0 awk '{print "  + " $0}'

# Delete old backups
echo "Deleting older backups"
ls -tp | grep -v '/$' | tail -n +6 | tr '\n' '\0' | xargs -0 rm --

# Clean up files now they're compressed
echo "Removing temporary files..."
rm -r "${BACKUP_DIR}/${WORLD_DIR}/${BACKUP_DATETIME}"

# Show backup file info
stat --format="Created backup file: '%n', size: %s bytes" "${BACKUP_DIR}/${WORLD_DIR}/${BACKUP_DATETIME}.tar.gz"

# Finished
echo "Backup Finished"
