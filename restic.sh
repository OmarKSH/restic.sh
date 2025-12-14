#!/bin/sh

#set -e #it causes the calling shell to exit when in source mode

cleanup() { [ -n "$OLD_PATH" ] && PATH="$OLD_PATH"; rm -rf "$bins_dir" "$restic" 2>/dev/null; unset BOOTMODE OLD_PATH SELF_NAME SELF SOURCE_DOTENV REPLY pwd restic repos action RESTIC_REPOSITORY; }

trap cleanup QUIT EXIT TERM
trap 'cleanup; return 2>/dev/null || exit;' INT
cleanup

[ -z $BOOTMODE ] && ps | grep zygote | grep -qv grep && BOOTMODE=true
[ -z $BOOTMODE ] && ps -A 2>/dev/null | grep zygote | grep -qv grep && BOOTMODE=true
[ -z $BOOTMODE ] && BOOTMODE=false

OLD_PATH="$PATH"
SELFNAME=restic.sh

# pwd="/data/media/0/restic"
#pwd="$(cd "$(dirname "$0")" && pwd)"
#if [ -f "$0" ]; then
#	true
#elif [ "$0" == 'bash' ]; then
#	pwd=$(dirname "$pwd/$BASH_SOURCE")
#else
#	pwd=$(dirname "$pwd/$0")
#fi

pwd="$PWD"
[ "${0##*/}" = "$SELFNAME" ] && pwd=$(dirname "$(realpath "$0")")
[ -n "$BASH_SOURCE" ] && pwd=`dirname "$(realpath "$BASH_SOURCE")"`
SELF="$pwd/$SELFNAME"

[ ! -f "$SELF" ] && echo "Sanity check failed! probably an error with the current directory detection in $SELFNAME script" && { return 1 2>/dev/null || exit 1; }
#[ `basename $0` = "$SELFNAME" ] && [ -z "$SOURCE_DOTENV" ] && echo 'This script should not be run directly!' && { return 1 2>/dev/null || exit 1; }

select_from_list() {
	{ [ "$1" != 'text' ] && [ -x "`command -v fzf`" ] && { fzf "$@" <&0; return $?; }; } \
	|| { local line i=0 REPLY \
	&& while IFS= read -r line; do [ -z "$line" ] && continue; echo "$i) $line" >/dev/tty; eval "local line$i=\"$line\""; i=$((i+1)); done \
	&& echo -n "Enter choice number: " >/dev/tty && read -r REPLY </dev/tty \
	&& eval "echo -n \"\${line$REPLY}\"" && echo >/dev/tty; }
}

remount_exec() {
	[ -n "$1" ] && local pwd="$1"

	mount -a 2>/dev/null || true
	mount /data 2>/dev/null || true

	# Try remounting the filesystem as executable first
	#mount -oremount,exec "$(realpath "$pwd"/../..)" 2>/dev/null || true
	while IFS= read -r line; do
		line="${line#* }"
		line="${line%% *}"
		case "$pwd" in
			*"$line"*) [ "$line" != '/' ] && mount -oremount,exec "$line" 2>/dev/null || true; break ;;
		esac
	done </proc/mounts
	# remount everything as exec
	while IFS= read -r line; do
		line="${line#* }"
		line="${path%% *}"
		case "$line" in
			*noexec*) echo mount -oremount,exec "$line" 2>/dev/null || true; break ;;
		esac
	done </proc/mounts
}

find_execable_dir() {
	[ -n "$1" ] && local pwd="$1"

	local bins_dir=
	for dir in "$TMPDIR" /tmp /dev /data/local/tmp "$pwd" "$PWD" ${PATH//:/ }; do
		f="$dir/test"
		[ -d "$dir" ] && touch "$f" && chmod +x "$f" && [ -x "$f" ] && rm -f "$f" && bins_dir="$dir" && break
		rm -f "$f"
	done
	echo -n "$bins_dir"
}

load_bins_from() {
	local bins_fullpath="$1"; shift
	local bins="$@"
	local missing_bins=

	[ -z "$bins" ] && bins="$bins_fullpath/*"
	[ -z "$bins" ] && return 1

	for bin in $bins; do type $bin >/dev/null 2>/dev/null || missing_bins="$bin $missing_bins"; done
	[ -z "$missing_bins" ] && return

	local bins_dir=`find_execable_dir`
	[ -z "$bins_dir" ] && return 1
	bins_dir="$bins_dir/__restic__bins__"
	rm -rf "$bins_dir"
	mkdir "$bins_dir" || { echo Cannot create directory to store the executables && { return 1 2>/dev/null || exit 1; } }

	cp -a "$missing_bins" "$bins_dir"

	case "$PATH" in
		*"$bins_dir"*) true ;;
		*) PATH="$PATH:$bins_dir" ;;
	esac

	chmod +x "$bins_dir"/*
	echo -n "$bins_dir"
}

get_payload_line() {
	local self="$0"
	[ -n "$1" ] && self="$1"

	local payload_line=1
	while IFS= read -r line; do
		[ "$line" = "__PAYLOAD_BEGINS__" ] && break
		payload_line=$((payload_line+1))
	done <"$self"

	echo -n "$payload_line"
}

extract_payload_from() {
	local bins_dir=`find_execable_dir`

	local self="$0"
	[ -n "$1" ] && self="$1"

	local bin="$bins_dir/resticoasdklf"
	local payload_line=`get_payload_line "$self"`

	tail -n+$((payload_line+1)) "$self" > "$bin"

	chmod +x "$bin"
	echo -n "$bin"
}

split_from() {
	local self="$0"
	[ -n "$1" ] && self="$1"

	local payload_line=`get_payload_line "$self"`

	head -n$payload_line "$self" > "$self.script"
	tail -n+$((payload_line+1)) "$self" > "$self.bin"
}

merge() {
	local self="$0"
	[ -n "$1" ] && self="$1"

	[ -r "$self.script" ] && [ -r "$self.bin" ] && cat "$self.script" "$self.bin" > "$self" 
}

is_restic_repo() {
	local dir="$1"
	[ -f "$dir/config" ] && [ -d "$dir/data" ] && [ -d "$dir/index" ] && [ -d "$dir/keys" ] && [ -d "$dir/locks" ] && [ -d "$dir/snapshots" ]
	return $?
}

generate_recovery_script() {
	local file="$1"
	local commands="$2"

	local filedir="$(realpath "${file%/*}")"
	file="$filedir/${file##*/}"

	# Create archive files
	mkdir -p "$filedir"/META-INF/com/google/android
	echo '#MAGISK' > "$filedir"/META-INF/com/google/android/update-script
	echo "id=$(basename "$file")" > "$filedir"/module.prop
	cat <<- 'EOF' > "$filedir"/customize.sh
	export PATH="$PATH:$MODPATH:/data/data/com.termux/files/usr/bin"
	id="$(basename "$MODPATH")"

	unzip -o -d "$MODPATH" "$ZIPFILE" || echo "Failed to extract required files"

	if [ -z "$SHELL" ]; then #If executing from GUI
		logfile=/data/media/0/"$id".log

		cp -a "$ZIPFILE" "$MODPATH"

		cat <<- 'EOF2' > "$MODPATH/post-fs-data.sh"
		rm -rf "${0%/*}"
		EOF2

		cat <<- EOF2 > "$MODPATH/daemon.sh"
		echo -e "\\n^^^^^^^^ \$(date) ^^^^^^^^\\n"
		sh "$MODPATH/META-INF/com/google/android/update-binary" _ _ "$MODPATH/$(basename "$ZIPFILE")"
		echo -e "\\n________ \$(date) ________\\n"
		rm -rf "$MODPATH" "${MODPATH/modules_update/modules}"
		EOF2

		daemonize -e "$logfile" -o "$logfile" $(which sh) "$MODPATH/daemon.sh" 2>/dev/null \
		&& echo "Running operation, the screen will freeze please wait! (logfile: $logfile)" \
		|| {
			rm -f "$MODPATH/daemon.sh" "$MODPATH/service.sh" "$MODPATH/post-fs-data.sh"

			cat <<- 'EOF2' > "$MODPATH/service.sh"
			MODDIR="${0%/*}"
			while read -r line; do [ "$line" != "${line#id=}" ] && logfile="/data/media/0/${line#id=}".log && break; done < "$MODDIR/module.prop"
			echo -e "\n^^^^^^^^ $(date) ^^^^^^^^\n" >"$logfile"
			sh "$MODDIR/META-INF/com/google/android/update-binary" _ _ "$(find "$MODDIR" -maxdepth 1 -type f -name '*.zip')" 2>&1 | tee -a "$logfile"
			echo -e "\n________ $(date) ________\n" >>"$logfile"
			rm -rf "$MODDIR"
			EOF2

			echo "Reboot to complete operation, logfile: $logfile"
		}
	else
		sh "$MODPATH/META-INF/com/google/android/update-binary" _ _ "$ZIPFILE" 2>&1
		rm -rf "$MODPATH" "${MODPATH/modules_update/modules}" 2>/dev/null
	fi
	EOF
	# When the delimiter is unquoted, the shell performs variable substitution and command substitution within the heredoc content. To prevent this, the delimiter can be enclosed in single quotes, which treats the content literally. An optional minus sign (<<-) can be used to ignore leading tab characters, allowing for indented code in scripts without altering the actual content. This is particularly useful for maintaining code readability in shell scripts.
	cat <<- EOF > "$filedir"/META-INF/com/google/android/update-binary 
	#!/sbin/sh

	set -o pipefail #This causes pipes to stop on first command that fail which is important for the self call trick to return the status correctly

	ZIP=\$3
	OUTFD=\$2

	[ -z \$BOOTMODE ] && ps | grep zygote | grep -qv grep && BOOTMODE=true
	[ -z \$BOOTMODE ] && ps -A 2>/dev/null | grep zygote | grep -qv grep && BOOTMODE=true
	[ -z \$BOOTMODE ] && [ -n "\$(getprop ro.boottime.zygote)" ] && BOOTMODE=true
	[ -z \$BOOTMODE ] && BOOTMODE=false

	ui_print() {
		\$BOOTMODE && { echo -e \$@; return \$?; }
		while IFS= read -r line 2>/dev/null; do echo -e "ui_print \$line\\nui_print" >/proc/self/fd/\$OUTFD; done
		[ \$# -gt 0 ] && echo -e "ui_print \$@\\nui_print" >/proc/self/fd/\$OUTFD
		return 0 #This line is important as incase the previous check failed it won't cause the while function to return an error code
	}

	! \$BOOTMODE && [ \$# -eq 3 ] && { cat>/dev/null; "\$0" "\$@" _ 2>&1 | ui_print; exit \$?; }

	airpln() {
	case "\$1" in
		"on")  { 
			settings put global airplane_mode_on 1 || true
			am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true >/dev/null || true
			#User_br=\`settings get system screen_brightness\` && settings put system screen_brightness \$((\$User_br / 3)) || true
			#User_to=\`settings get system screen_off_timeout\` && settings put system screen_off_timeout 3600000 || true
			#User_br_mode=\`settings get system screen_brightness_mode\` && settings put system screen_brightness_mode 0 || true
			#User_plug=\`settings get global stay_on_while_plugged_in\` && settings put global stay_on_while_plugged_in 7 || true
		} ;;
		"off") {
			settings put global airplane_mode_on 0 || true
			am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false >/dev/null || true
			#settings put system screen_brightness "\$User_br" || true
			#settings put system screen_off_timeout "\$User_to" || true
			#settings put system screen_brightness_mode "\$User_br_mode" || true
			#settings put global stay_on_while_plugged_in "\$User_plug" || true
		} ;;
	esac
	}

	cleanup() { rm -rf "\$tmpdir"; }
	trap 'cleanup' EXIT QUIT TERM

	for d in "\$TMPDIR" /tmp /dev "\$PWD"; do [ -w "\$d" ] && export TMPDIR="\$d" && break; done
	tmpdir=\`mktemp -d\`

	unzip -o -d "\$tmpdir" "\$ZIP" "$SELFNAME" >/dev/null
	chmod -R +x "\$tmpdir"

	restic_sh="\$tmpdir/$SELFNAME"

	RESTIC_REPOSITORY="$(realpath "$RESTIC_REPOSITORY")"
	[ ! -d "\$RESTIC_REPOSITORY" ] && ui_print "Searching for the repository...." \\
	&& { RESTIC_REPOSITORY="\$(dirname "\$(dirname "\$(find "\$(dirname "\$ZIP")" / -type f -name "$filename" -print -quit 2>/dev/null)")")" \\
		&& ui_print "Found at \$RESTIC_REPOSITORY" || { ui_print "Couldn't find the repository!" && exit 1; } }

	$commands

	cleanup
	EOF

	# Backup previous recovery archive
	[ -f "$file" ] && mv "$file" "$file"_

	# Use termux binaries if termux is installed
	local PATH_BAK="$PATH"
	PATH="$PATH:/data/data/com.termux/files/usr/bin"
	# Create recovery archive
	local OLD_PWD="$PWD"
	cd "$filedir"
	echo "Creating recovery archive $file"
	{ { zip -0 -j "$file" "$SELF" && { zip -0 -r "$file" META-INF module.prop customize.sh; true; } } \
	|| { 7z && { 7z -mx=0 a "$file" "$SELF" META-INF module.prop customize.sh; true; } } \
	|| { 7za && { 7za -mx=0 a "$file" "$SELF" META-INF module.prop customize.sh; true; } } } >/dev/null 2>/dev/null \
	|| echo "Failed to create recovery archive $file, no archiving binaries available"
	cd "$OLD_PWD"
	# Restore PATH value
	PATH="$PATH_BAK"

	# Delete previous recovery archive if a new one was created
	[ -f "$file" ] && rm -f "$file"_ || { [ -f "$file"_ ] && mv "$file"_ "$file"; }

	# Cleanup
	rm -rf "$filedir"/META-INF "$filedir"/module.prop "$filedir"/customize.sh
}

generate_recovery_backup_script() {
	local backup_path="$1"
	local commands=

	{ [ -z "$backup_path" ] || [ -z "$RESTIC_REPOSITORY" ]; } && return 1

	local filedir="$RESTIC_REPOSITORY/.BACKUP"
	local filename="backup-${backup_path//[\/ ]/_}.zip"

	mkdir "$filedir" 2>/dev/null || true

	commands=$(cat <<- EOF
	DATA_OPERATION=`echo $backup_path | grep -q -E '(/| /)data( |/ |/$|$)' && echo true || echo false`
	\$DATA_OPERATION && {
		mount /data 2>/dev/null
		\$BOOTMODE && airpln "on" && ui_print "Stopping zygote!" && sleep 1 && stop
	}
	echo "$RESTIC_PASSWORD" | sh "\$restic_sh" backup "\$RESTIC_REPOSITORY" "$backup_path"
	\$DATA_OPERATION && \$BOOTMODE && {
		start
		echo 'Waiting for bootup'
		while ! pgrep zygote >/dev/null || [ \`getprop service.bootanim.exit\` -eq 0 ]; do sleep 1; done
		airpln "off"
	}
	EOF
	)

	generate_recovery_script "$filedir/$filename" "$commands"
}

generate_recovery_restore_scripts() {
	local restore_path="${1:-/}"
	local commands=

	{ [ -z "$restore_path" ] || [ -z "$RESTIC_REPOSITORY" ]; } && return 1

	local filedir="$RESTIC_REPOSITORY/.RESTORE"

	rm -rf "$filedir"
	mkdir "$filedir" 2>/dev/null || true

	local line=
	"$restic" snapshots | while IFS= read -r line; do
		case "$line" in *[0-9]-[0-9]*) true ;; *) continue ;; esac
		line="${line//  /__}"; line="${line//_ /__}"; line="$(echo "$line" | tr -s '_')"
		local id="${line%%_*}"; line="${line#*_}"
		local time="${line%%_*}"; line="${line#*_}"
		local host="${line%%_*}"; line="${line#*_}"
		local tags="${line%%_*}"; line="${line#*_}"
		local paths="${line%%_*}"; line="${line#*_}"
		local size="${line%%_*}"
		[ "$size" = "$paths" ] && paths="$tags" && tags=

		local filename="restore-${time//[: ]/_}-${paths//\//_}.zip"
		[ -n "$tags" ] && filename="$filename-${tags//[: ]/_}"

		commands=$(cat <<- EOF
		echo "$RESTIC_PASSWORD" | sh "\$restic_sh" restic -r "\$RESTIC_REPOSITORY" snapshots "$id" | grep 'Time' >/dev/null && ID_EXISTS=true
		[ -z "\$ID_EXISTS" ] && echo "Snapshot $id doesn't exist!" && exit 1
		DATA_OPERATION=`echo $paths | grep -q -E '(/| /)data( |/ |/$|$)' && echo true || echo false`
		\$DATA_OPERATION && {
			mount /data 2>/dev/null
			ui_print "Wiping /data without wiping /data/media"
			\$BOOTMODE && { airpln "on"; ui_print "Stopping zygote!"; sleep 1; stop; }
			find /data -maxdepth 1 ! -path /data ! -path /data/media ! -path /data/cache ! -path /data/gsi ! -path /data/lost+found ! -path /data/misc ! -path /data/per_boot ! -path /data/recovery ! -path /data/unencrypted -exec rm -rf "{}" +
			find /data/misc -maxdepth 1 ! -path /data/misc ! -path /data/misc/gatekeeper ! -path /data/misc/keystore ! -path /data/misc/vold ! -path /data/misc/adb -exec rm -rf "{}" +
		}
		echo "$RESTIC_PASSWORD" | sh "\$restic_sh" restore "\$RESTIC_REPOSITORY" "$id" "$(realpath "$restore_path")"
		\$DATA_OPERATION && \$BOOTMODE && reboot
		EOF
		)

		generate_recovery_script "$filedir/$filename" "$commands"
	done
}

backup() {
	##!/bin/sh
	#
	##set -e
	#
	#pwd=`dirname "$(realpath "$PWD/$0")"`
	#[ -n "$BASH_SOURCE" ] && pwd=`dirname "$(realpath "${BASH_SOURCE}" 2>/dev/null)"`
	#
	#SOURCE_DOTENV=1 && . "$pwd/.env"
	#unset pwd SOURCE_DOTENV

	#export TMPDIR="$pwd/.tmp"
	#export RESTIC_CACHE_DIR="$pwd/.cache"
	#[ ! -e "$TMPDIR" ] && mkdir -p "$TMPDIR"; f
	#[ ! -e "$RESTIC_CACHE_DIR" ] &&  mkdir -p "$RESTIC_CACHE_DIR"

	local backup_path="$1"; [ -n "$1" ] && shift
	local backup_paths="Enter paths manually\n/data -e /data/media\n/data/media"
	while [ -z "$backup_path" ]; do echo 'Select backup string:' && backup_path="$(echo -e "$backup_paths" | select_from_list)"; done
	[ "$backup_path" = 'Enter paths manually' ] && echo -n "Enter backup string: " && read -r backup_path </dev/tty && echo

	generate_recovery_backup_script "$backup_path"

	local excludes="-e '$RESTIC_REPOSITORY'"
	diff -qr /data/data /data/user/0 >/dev/null 2>/dev/null && excludes="$excludes -e /data/user/0" || echo 'including /data/user/0 in backup'

	"$restic" --no-cache --no-lock backup $backup_path $excludes "$@"

	"$restic" --no-cache prune

	generate_recovery_restore_scripts "/"
}

restore() {
	##!/bin/sh
	#
	##set -e
	#
	#pwd=`dirname "$(realpath "$PWD/$0")"`
	#[ -n "$BASH_SOURCE" ] && pwd=`dirname "$(realpath "${BASH_SOURCE}" 2>/dev/null)"`
	#
	#SOURCE_DOTENV=1 && . "$pwd/.env"
	#unset pwd SOURCE_DOTENV

	local id="$1"; [ -n "$1" ] && shift
	if [ -z "$id" ]; then
		echo 'Loading snapshots list...'

		local raw_snapshots=`"$restic" snapshots`
		[ -z "$raw_snapshots" ] && echo 'No snapshots in the repo!' && { return 1 2>/dev/null || exit 1; }

		local snapshots=
		tmp="$(basename $(mktemp -u))"
		echo -e "$raw_snapshots" >"$tmp"
		while IFS= read -r line; do case "$line" in *[0-9]-[0-9]*) snapshots="$line\n$snapshots" ;; esac done <"$tmp"
		rm "$tmp"

		while [ -z "$id" ]; do echo 'Select snapshot to be restored:'; id=`echo -e "$snapshots" | select_from_list` && id=${id%% *}; done
	fi

	local target="$1"; [ -n "$1" ] && shift
	if [ -z "$target" ]; then
		echo -n 'Enter restore target (default /): ' && read -r target </dev/tty && echo
		[ -z "$target" ] && target='/'
	fi

	local excludes="-e '$RESTIC_REPOSITORY' -e /data/system/gatekeeper.password.key -e /data/system/gatekeeper.pattern.key -e /data/system/locksettings.db -e /data/system/locksettings.db-shm -e /data/system/locksettings.db-wal"

	#echo -n 'Delete fingerprint data (y/N)? ' \
	#	&& read -r REPLY && { [ "$REPLY" = 'y' ] || [ "$REPLY" = 'Y' ]; } \
	#	&& excludes="$excludes -e /data/system/users/0/fpdata -e /data/system/users/0/settings_fingerprint.xml" \
	#	&& echo

	"$restic" --no-cache --no-lock restore --sparse -t "$target" $excludes $id "$@"
}

nightly() {
	[ ! -d "$RESTIC_REPOSITORY" ] && "$restic" --no-cache init

	backup "/data -e /data/media" "$@"

	"$restic" --no-cache forget --prune --keep-last 10 --keep-daily 7 --keep-weekly 5 --keep-monthly 12
}

#run_schedule() {
#	local trigger_time_input="$1"; #shift
#	local trigger_time_default="03:00"
#	local trigger_time_file="$pwd/.$(basename "$0").TRIGGER_TIME"
#
#	local RESTIC_REPOSITORY_input="$1"; [ -n "$1" ] && shift
#	local RESTIC_REPOSITORY_default=${RESTIC_REPOSITORY_input:-"$pwd/repo"}
#	#local RESTIC_REPOSITORY_file="$pwd/.$(basename "$0").RESTIC_REPO"
#	local RESTIC_REPOSITORY_file="$pwd/.$SELFNAME.RESTIC_REPO"
#	export RESTIC_REPOSITORY="$RESTIC_REPOSITORY_default"
#
#	local RESTIC_PASSWORD_input="$1"; [ -n "$1" ] && shift
#	local RESTIC_PASSWORD_default=${RESTIC_PASSWORD_input:-BUZZWORD}
#	#local RESTIC_PASSWORD_file="$pwd/.$(basename "$0").RESTIC_PASS"
#	local RESTIC_PASSWORD_file="$pwd/.$SELFNAME.RESTIC_PASS"
#	export RESTIC_PASSWORD="$RESTIC_PASSWORD_default"
#
#	echo_schedule_banner
#
#	while true; do
#		# make sure that the sleep time wont cause a skip
#		# ex: the script should run at hour 00:00 but we
#		# started sleeping at 23:59, so we must sleep for
#		# less than a minute but at the same time sleep
#		# long enough to not cause trigger multiple times
#		# ex: if we sleep for 1 sec and run the script on
#		# 00:00 then it will keep triggering for a whole
#		# minute until 00:01
#		local trigger_time="$trigger_time_default"
#		{ [ -n "$trigger_time_input" ] && trigger_time="$trigger_time_input"; } \
#		|| { [ -r "$trigger_time_file" ] && { read -r trigger_time <"$trigger_time_file" || true; } }
#
#		echo -e "\rPerform backup at $trigger_time, current time: $(date +%H:%M)"
#
#		[ "$(date +%H:%M)" = "$trigger_time" ] && nightly \
#
#		&& while [ "$(date +%H:%M)" = "$trigger_time" ]; do sleep 10; done # guard check to prevent multiple triggers
#
#		sleep 50
#	done
#}

run_schedule() {
	calculate_trigger_date() {
		trigger_date="$(date +%s -d"$trigger_time")"
		[ $(date +%s) -ge $trigger_date ] && trigger_date=$((trigger_date+86400))
	}

	local trigger_time_input="$1"; [ -n "$1" ] && shift
	local trigger_time=${trigger_time_input:-'03:00'}
	#local trigger_time_file="$pwd/.$(basename "$0").TRIGGER_TIME"
	local trigger_time_file="$pwd/.$SELFNAME.TRIGGER_TIME"
	local trigger_date=

	local RESTIC_REPOSITORY_input="$1"; [ -n "$1" ] && shift
	local RESTIC_REPOSITORY_default=${RESTIC_REPOSITORY_input:-"$pwd/repo"}
	#local RESTIC_REPOSITORY_file="$pwd/.$(basename "$0").RESTIC_REPO"
	local RESTIC_REPOSITORY_file="$pwd/.$SELFNAME.RESTIC_REPO"
	export RESTIC_REPOSITORY="$RESTIC_REPOSITORY_default"

	local RESTIC_PASSWORD_input="$1"; [ -n "$1" ] && shift
	local RESTIC_PASSWORD_default=${RESTIC_PASSWORD_input:-BUZZWORD}
	#local RESTIC_PASSWORD_file="$pwd/.$(basename "$0").RESTIC_PASS"
	local RESTIC_PASSWORD_file="$pwd/.$SELFNAME.RESTIC_PASS"
	export RESTIC_PASSWORD="$RESTIC_PASSWORD_default"

	[ -z "$trigger_time_input" ] && [ -r "$trigger_time_file" ] && read -r trigger_time <"$trigger_time_file"

	calculate_trigger_date

	echo "You can customize the password by writing it to this file: $RESTIC_PASSWORD_file"
	echo "You can customize the repository location by writing it to this file: $RESTIC_REPOSITORY_file"
	echo "You can customize the trigger time by writing it to this file: $trigger_time_file"

	while true; do
		[ -z "$RESTIC_REPOSITORY_input" ] && [ -r "$RESTIC_REPOSITORY_file" ] && { read -r RESTIC_REPOSITORY <"$RESTIC_REPOSITORY_file" || true; }
		[ -z "$RESTIC_PASSWORD_input" ] && [ -r "$RESTIC_PASSWORD_file" ] && { read -r RESTIC_PASSWORD <"$RESTIC_PASSWORD_file" || true; }

		echo -e "\rPerform backup at $(date -d"@$trigger_date"), current time: $(date)"

		[ $(date +%s) -ge $(date +%s -d"@$trigger_date") ] && nightly "$@" && calculate_trigger_date

		[ -z "$trigger_time_input" ] && [ -r "$trigger_time_file" ] && { read -r trigger_time <"$trigger_time_file" || true; } && calculate_trigger_date

		sleep 60
	done
}

{ [ "$1" = 'split' ] && { split_from "$SELF"; { return $? 2>/dev/null || exit $?; } } } \
|| { [ "$1" = 'merge' ] && { merge "$SELF"; { return $? 2>/dev/null || exit $?; } } }

# handle cases where TMPDIR is not defined
export TMPDIR
for TMPDIR in "$TMPDIR" /tmp /dev /data/local/tmp "$pwd" "$PWD"; do
	[ -w "$TMPDIR" ] && break
done

#bins_fullpath="$pwd/bin"
#bins="$bins_fullpath/restic $bins_fullpath/fusermount $bins_fullpath/fzf"
#case "$PATH" in
#	*"$bins_fullpath"*) true ;;
#	*) PATH="$PATH:$bins_fullpath" ;;
#esac
#remount_exec
#bins_dir=load_bins_from "$bins_fullpath" $bins
#restic=`command -v restic`
#unset bins_fullpath bins

restic=`extract_payload_from "$SELF"`

# If on Android set RESTIC_HOST
#export RESTIC_HOST="$(getprop ro.product.name 2>/dev/null)"

export RESTIC_PASSWORD
# If the password is piped to the script then read it into a variable
[ ! -t 0 ] && IFS= read -r RESTIC_PASSWORD

action="$1"
case "$action" in
	restic) shift; "$restic" "$@"; return $? 2>/dev/null || exit $? ;;
	schedule) shift; run_schedule "$@"; return $? 2>/dev/null || exit $? ;;
	nightly|backup|restore) shift ;; #those will be executed later in the script
	*) unset action ;;
esac

export RESTIC_REPOSITORY=$1; [ -n "$1" ] && shift

[ "$action" = 'nightly' ] && { nightly "$@"; { return $? 2>/dev/null || exit $?; } }

# Find the repos in the current directory and the directory where the script exists
if [ -z "$RESTIC_REPOSITORY" ]; then
	for dir in `find $([ "$pwd" = "$PWD" ] && echo "$pwd" || echo -e "$pwd\n$PWD") -maxdepth 1 -type d`; do
		is_restic_repo "$dir" && repos="$dir\n$repos"
	done
	repos="Enter path manually\n$repos\n"
	while [ -z "$RESTIC_REPOSITORY" ]; do echo 'Select repository:'; RESTIC_REPOSITORY=`echo -en "$repos" | select_from_list`; done
	[ "$RESTIC_REPOSITORY" = 'Enter path manually' ] && RESTIC_REPOSITORY=
	while [ -z "$RESTIC_REPOSITORY" ]; do echo -n "Enter repo path: " && read -r RESTIC_REPOSITORY </dev/tty && echo; done
	unset repos
fi

#[ -z "$RESTIC_REPOSITORY" ] && { echo "No restic repository found"; exit 2>/dev/null || return; }

[ -z "$RESTIC_PASSWORD" ] && echo -e "\033[38;5;3mYou should source this script at least once instead of running it so that you won't have to input the password everytime\e[0m"
while [ -z "$RESTIC_PASSWORD" ]; do echo -n 'Enter repo password: ' && { read -r -s RESTIC_PASSWORD 2>/dev/null || read -r RESTIC_PASSWORD; } && echo; done

[ ! -d "$RESTIC_REPOSITORY" ] && { echo -n "The repository $RESTIC_REPOSITORY doesn't exist, create it? (Y/n) " && read -r REPLY && echo; { [ -z "$REPLY" ] || [ "$REPLY" = 'y' ] || [ "$REPLY" = 'Y' ]; } && { "$restic" init && sleep 2; } || { return 2>/dev/null || exit; } }

while ! "$restic" snapshots >/dev/null; do echo -n 'Enter repo password: ' && { read -r -s RESTIC_PASSWORD 2>/dev/null || read -r RESTIC_PASSWORD; } && echo; done

#[ -n "$SOURCE_DOTENV" ] && return 2>/dev/null #if the script is sourced the cleanup should run at the end of the parent script not here

#cleanup

# Choose action to be performed
while [ -z "$action" ]; do echo 'Select action to perform:'; action=`echo -e "restore\nbackup" | select_from_list -1`; done 
{ [ "$action" = "restore" ] && restore "$@"; } \
|| { [ "$action" = "backup" ] && backup "$@"; }
unset action

{ return 2>/dev/null || exit; }
__PAYLOAD_BEGINS__
