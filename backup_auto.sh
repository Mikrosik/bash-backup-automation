#!/usr/bin/env bash
# Пример записи в cron  (ежедневно в 02:00):
# 0 2 * * * BACKUP_SOURCE=/srv/data BACKUP_DEST=backup@host:/srv/backups LOG_FILE=/var/log/server-backup.log /usr/local/sbin/bash_backup_auto

# BACKUP_DEST может быть также локальным путём. Каталог назначения создаётся автоматически при необходимости.

# Укажите в LOG_FILE и LOCK_FILE пути, доступные для записи пользователю, от имени которого работает cron.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

BACKUP_SOURCE=${BACKUP_SOURCE:-}
BACKUP_DEST=${BACKUP_DEST:-}
LOG_FILE=${LOG_FILE:-"${HOME:-/tmp}/.local/state/bash_backup_auto/backup.log"}
LOCK_FILE=${LOCK_FILE:-"${TMPDIR:-/tmp}/bash_backup_auto-${UID}.lock"}
LOG_MAX_BYTES=${LOG_MAX_BYTES:-10485760}
LOG_KEEP=${LOG_KEEP:-5}
MIN_FREE_KB=${MIN_FREE_KB:-102400}
CONNECT_TIMEOUT=${CONNECT_TIMEOUT:-15}
RSYNC_TIMEOUT=${RSYNC_TIMEOUT:-600}
RSYNC_RSH=${RSYNC_RSH:-"ssh -o BatchMode=yes -o ConnectTimeout=${CONNECT_TIMEOUT} -o ServerAliveInterval=15 -o ServerAliveCountMax=3"}

log() {
	printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE"
}

die() {
	log "ERROR: $*"
	exit 1
}

on_error() {
	local status=$1
	local command=$2
	trap - ERR
	log "ERROR: command failed (status=$status, line=${BASH_LINENO[0]:-unknown}): $command" || true
	exit "$status"
}

trap 'on_error "$?" "$BASH_COMMAND"' ERR

rotate_log() {
	local size
	size=$(wc -c < "$LOG_FILE")
	if (( size < LOG_MAX_BYTES )); then
		return
	fi

	local index previous
	for ((index = LOG_KEEP; index > 0; index--)); do
		if (( index == 1 )); then
			previous=$LOG_FILE
		else
			previous="$LOG_FILE.$((index - 1))"
		fi
		if [[ -f $previous ]]; then
			mv -f -- "$previous" "$LOG_FILE.$index"
		fi
	done
	: > "$LOG_FILE"
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || {
		printf 'Required command not found: %s\n' "$1" >&2
		exit 127
	}
}

validate_number() {
	local name=$1 value=$2 minimum=$3
	[[ $value =~ ^[0-9]+$ ]] || {
		printf '%s must be a non-negative integer\n' "$name" >&2
		exit 64
	}
	(( 10#$value >= minimum )) || {
		printf '%s must be at least %s\n' "$name" "$minimum" >&2
		exit 64
	}
}

shell_quote() {
	local value=$1
	value=${value//\'/\'\\\'\'}
	printf "'%s'" "$value"
}

available_kb_from_df() {
	local output available
	output=$(df -Pk -- "$1") || return 1
	available=$(awk 'END { print $4 }' <<< "$output")
	[[ $available =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$available"
}

main() {
	[[ -n $BACKUP_SOURCE && -n $BACKUP_DEST ]] || {
		printf 'Set BACKUP_SOURCE and BACKUP_DEST before running this script.\n' >&2
		exit 64
	}
	[[ $BACKUP_SOURCE == /* ]] || {
		printf 'BACKUP_SOURCE must be an absolute path.\n' >&2
		exit 64
	}

	validate_number LOG_MAX_BYTES "$LOG_MAX_BYTES" 1
	validate_number LOG_KEEP "$LOG_KEEP" 0
	validate_number MIN_FREE_KB "$MIN_FREE_KB" 0
	validate_number CONNECT_TIMEOUT "$CONNECT_TIMEOUT" 1
	validate_number RSYNC_TIMEOUT "$RSYNC_TIMEOUT" 1
	LOG_MAX_BYTES=$((10#$LOG_MAX_BYTES))
	LOG_KEEP=$((10#$LOG_KEEP))
	MIN_FREE_KB=$((10#$MIN_FREE_KB))
	CONNECT_TIMEOUT=$((10#$CONNECT_TIMEOUT))
	RSYNC_TIMEOUT=$((10#$RSYNC_TIMEOUT))

	require_command rsync
	require_command flock
	require_command realpath
	require_command du
	require_command df
	require_command awk
	require_command date
	require_command wc
	require_command mv
	require_command mkdir

	mkdir -p -- "$(dirname -- "$LOG_FILE")"
	touch -- "$LOG_FILE"
	mkdir -p -- "$(dirname -- "$LOCK_FILE")"
	exec 9>"$LOCK_FILE"
	if ! flock -n 9; then
		log 'Another backup run is active; skipping this run.'
		return 0
	fi

	rotate_log

	local source_path source_size_kb du_output required_kb
	source_path=$(realpath -e -- "$BACKUP_SOURCE") || die "source does not exist: $BACKUP_SOURCE"
	[[ -d $source_path && -r $source_path ]] || die "source is not a readable directory: $source_path"
	du_output=$(du -skx -- "$source_path") || die 'could not estimate source size'
	source_size_kb=${du_output%%$'\t'*}
	[[ $source_size_kb =~ ^[0-9]+$ ]] || die 'could not parse source size'
	required_kb=$((source_size_kb + MIN_FREE_KB))

	local remote_host='' remote_path='' destination_path='' available_kb quoted_path remote_df
	local -a ssh_command
	if [[ $BACKUP_DEST == *:* && $BACKUP_DEST != /* ]]; then
		remote_host=${BACKUP_DEST%%:*}
		remote_path=${BACKUP_DEST#*:}
		[[ $remote_host =~ ^[a-zA-Z0-9._@-]+$ && $remote_path == /* ]] || die 'remote destination must use [user@]host:/absolute/path'
		require_command ssh
		IFS=' ' read -r -a ssh_command <<< "$RSYNC_RSH"
		[[ ${ssh_command[0]:-} == ssh ]] || die 'RSYNC_RSH must start with ssh'
		quoted_path=$(shell_quote "$remote_path")

		log "Checking remote destination $remote_host:$remote_path"
		"${ssh_command[@]}" -- "$remote_host" "mkdir -p -- $quoted_path" || die 'could not reach remote destination or create its directory'
		remote_df=$("${ssh_command[@]}" -- "$remote_host" "df -Pk -- $quoted_path") || die 'remote disk-space check failed (network or SSH error)'
		available_kb=$(awk 'END { print $4 }' <<< "$remote_df")
		[[ $available_kb =~ ^[0-9]+$ ]] || die 'could not read available space on remote destination'
	else
		[[ $BACKUP_DEST == /* ]] || die 'local BACKUP_DEST must be an absolute path'
		mkdir -p -- "$BACKUP_DEST"
		destination_path=$(realpath -e -- "$BACKUP_DEST") || die 'could not resolve local destination'
		local source_prefix=$source_path destination_prefix=$destination_path
		[[ $source_prefix == / ]] || source_prefix+=/
		[[ $destination_prefix == / ]] || destination_prefix+=/
		[[ $source_path != "$destination_path" && $destination_path != "$source_prefix"* && $source_path != "$destination_prefix"* ]] || die 'source and destination directories must not overlap'
		available_kb=$(available_kb_from_df "$destination_path") || die 'could not check free space on local destination'
	fi

	if (( available_kb < required_kb )); then
		die "not enough free space: ${available_kb} KiB available, at least ${required_kb} KiB required"
	fi

	log "Starting backup from $source_path to $BACKUP_DEST (source estimate: ${source_size_kb} KiB)"
	local rsync_status
	if [[ -n $remote_host ]]; then
		if rsync -a -x --human-readable --partial-dir=.rsync-partial \
			--timeout="$RSYNC_TIMEOUT" \
			-e "$RSYNC_RSH" -- "$source_path/" "$remote_host:$remote_path/" >> "$LOG_FILE" 2>&1; then
			log 'Backup completed successfully.'
		else
			rsync_status=$?
			case $rsync_status in
				10|12|30|35|255) log "ERROR: network, SSH, or rsync connection failure (rsync exit $rsync_status)." ;;
				11|23) log "ERROR: file I/O or partial transfer (possible disk-space limit; rsync exit $rsync_status)." ;;
				*) log "ERROR: rsync failed with exit $rsync_status." ;;
			esac
			exit "$rsync_status"
		fi
	else
		if rsync -a -x --human-readable --partial-dir=.rsync-partial \
			--timeout="$RSYNC_TIMEOUT" -- "$source_path/" "$destination_path/" >> "$LOG_FILE" 2>&1; then
			log 'Backup completed successfully.'
		else
			rsync_status=$?
			case $rsync_status in
				11|23) log "ERROR: file I/O or partial transfer (possible disk-space limit; rsync exit $rsync_status)." ;;
				*) log "ERROR: rsync failed with exit $rsync_status." ;;
			esac
			exit "$rsync_status"
		fi
	fi
}

main "$@"
