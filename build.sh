#!/bin/sh

set -e

trap 'cd $OLD_PWD' EXIT QUIT TERM INT

OLD_PWD="$PWD"
cd "${0%/*}" 2>/dev/null || true

mkdir bin 2>/dev/null || true

[ ! -f "$payload_extractor" ] && [ ${#1} -gt 0 ] && payload_extractor="$(find -L bin -maxdepth 1 -type f -name "$1" -print0 -quit)"
[ ! -f "$payload_extractor" ] && [ ${#1} -gt 0 ] && payload_extractor="$(find -L bin -maxdepth 1 -type f -name "*$1*" -print0 -quit)"
[ ! -f "$payload_extractor" ] && payload_extractor=bin/unzipsfx
[ ! -f "$payload_extractor" ] && payload_extractor=bin/unzip
[ ! -f "$payload_extractor" ] && payload_extractor=bin/tiny7zx
[ ! -f "$payload_extractor" ] && payload_extractor=bin/7za
[ ! -f "$payload_extractor" ] && payload_extractor=bin/7z
[ ! -f "$payload_extractor" ] && echo "No supported payload extractor binary" && exit 1
echo "Will use payload extractor: $payload_extractor"

inpayload_archiver="$PWD/bin/zip"
[ ! -f "$inpayload_archiver" ] && inpayload_archiver="$PWD/bin/7za"
[ ! -f "$inpayload_archiver" ] && inpayload_archiver="$PWD/bin/7z"
[ ! -f "$inpayload_archiver" ] && echo "Couldn't find 7z or zip binaries to be added to the payload!" && exit 1

binaries="$PWD/bin/restic $PWD/bin/daemonize"
for bin in $binaries; do
	[ ! -e "$bin" ] && echo "$bin binary not found!" && exit 1
done

payload_extractor_name="${payload_extractor##*/}"
if [ "$payload_extractor_name" != "${payload_extractor_name#*tiny7zx}" ]; then
	bin/7za a -t7z -m0=lzma -mx=0 -ms=50m -ms=on bin/payload "$inpayload_archiver" $binaries 2>/dev/null \
		|| bin/7z a -t7z -m0=lzma -mx=0 -ms=50m -ms=on bin/payload "$inpayload_archiver" $binaries 2>/dev/null \
		|| 7za a -t7z -m0=lzma -mx=0 -ms=50m -ms=on bin/payload "$inpayload_archiver" $binaries 2>/dev/null \
		|| 7z a -t7z -m0=lzma -mx=0 -ms=50m -ms=on bin/payload "$inpayload_archiver" $binaries 2>/dev/null \
		|| { echo "No available 7z archivers" && exit 1; }
elif [ "$payload_extractor_name" != "${payload_extractor_name#*7z*}" ]; then
	bin/7za a -t7z -mx=7 bin/payload "$inpayload_archiver" $binaries 2>/dev/null \
		|| bin/7z a -t7z -mx=7 bin/payload "$inpayload_archiver" $binaries 2>/dev/null \
		|| 7za a -t7z -mx=7 bin/payload "$inpayload_archiver" $binaries 2>/dev/null \
		|| 7z a -t7z -mx=7 bin/payload "$inpayload_archiver" $binaries 2>/dev/null \
		|| { echo "No available 7z archivers" && exit 1; }
elif [ "$payload_extractor_name" != "${payload_extractor_name#*zip*}" ]; then
	bin/zip -7 -j bin/payload "$inpayload_archiver" $binaries 2>/dev/null \
		|| bin/7za a -tzip -mx=7 bin/payload "$inpayload_archiver" $binaries 2>/dev/null \
		|| bin/7z a -tzip -mx=7 bin/payload "$inpayload_archiver" $binaries 2>/dev/null \
		|| zip -7 -j bin/payload "$inpayload_archiver" $binaries 2>/dev/null \
		|| 7za a -tzip -mx=7 bin/payload "$inpayload_archiver" $binaries 2>/dev/null \
		|| 7z a -tzip -mx=7 bin/payload "$inpayload_archiver" $binaries 2>/dev/null \
		|| { echo "No available zip archivers" && exit 1; }
else
	echo "$payload_extractor_name is not a supported payload extractor binary"
	exit 1
fi

cat restic.sh "$payload_extractor" bin/payload.* > bin/restic.sh
chmod u+x bin/restic.sh

rm bin/payload.*