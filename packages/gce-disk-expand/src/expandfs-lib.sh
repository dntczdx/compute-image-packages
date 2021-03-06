#!/bin/sh
# Copyright 2018 Google Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

resize_filesystem() {
  local disk="$1" fs_type=""

  if ! fs_type=$(blkid_get_fstype "$disk"); then
    echo "$fs_type"
    return 1
  fi

  case "${fs_type}" in
    xfs)
      echo "XFS filesystems must be mounted to be resized, deferring."
      echo "true" > /tmp/xfs_resize
      return 1
      ;;
    ext*)
      if ! out=$(e2fsck -pf "$disk"); then
        echo "Calling e2fsck \"${disk}\" failed: ${out}"
        return 1
      fi
      if ! out=$(resize2fs "$disk"); then
        echo "Calling resize2fs \"${disk}\" failed: ${out}"
        return 1
      fi
      ;;
    *)
      echo "Unsupported filesystem type ${fs_type}, unable to expand size."
      return 1
      ;;
  esac
}

blkid_get_fstype() (
    local root="$1"

    if ! out=$(blkid -o udev "$root"); then
        echo "Detecting fstype by blkid failed: ${out}"
        return 1
    fi

    eval "$out"
    if [ -z "$ID_FS_TYPE" ]; then
        echo "No ID_FS_TYPE from blkid."
        return 1
    fi
    echo $ID_FS_TYPE
)


# Checks for and corrects the end-of-disk GPT backup block in case of expanded
# disk.
parted_fix_gpt() {
  local disk="$1"
  [ -z "$disk" ] && return

  if parted -sm "$rootdisk" print 2>&1 | grep "fix the GPT"; then
    # Running parted prompts the user to fix this condition, but only does so in
    # the interactive exception handler. In order to pass input we must use the
    # hidden triple-dash flag and pass both print and Fix arguments. `print`
    # alone will not perform the fix, but `Fix` alone will fail the argument
    # parser.
    parted -m ---pretend-input-tty "$rootdisk" print Fix
    if parted -sm "$rootdisk" print 2>&1 | grep "fix the GPT"; then
      echo "Failed to fix the GPT."
      return 1
    fi
  fi
}

# Returns "disk:partition", supporting multiple block types.
split_partition() {
  local root="$1" disk="" partnum=""
  [ -z "$root" ] && return

  if [ -e /sys/block/${root##*/} ]; then
    echo "Root is not a partition, skipping partition resize."
    return 1
  fi

  disk=${root%%p[0-9]*}
  [ "$disk" = "$root" ] && disk=${root%%[0-9]}

  partnum=${root#${disk}}
  partnum=${partnum#p}

  echo "${disk}:${partnum}"
}

# Checks if partition needs resizing.
parted_needresize() {
  local disk="$1" partnum="$2" disksize="" partend=""
  [ -z "$root" ] && return

  if ! out=$(parted -sm "$disk" unit b print 2>&1); then
    echo "Failed to get disk details: ${out}"
    return 1
  fi

  if ! echo -e "$out" | sed '$!d' | grep -q "^${partnum}:"; then
    echo "Root partition is not final partition on disk. Not resizing."
    return 1
  fi

  disksize=$(echo -e "$out" | grep "^${disk}" | cut -d: -f2)
  partend=$(echo -e "$out" | sed '$!d' | cut -d: -f4)
  [ -n "$disksize" -a -n "$partend" ] || return 1

  disksize=${disksize%%B}
  partend=${partend%%B}

  # Check if the distance is > .5GB
  [ $((disksize-partend)) -gt 536870912 ]
  return
}

# Resizes partition using 'resizepart' command.
parted_resizepart() {
  local disk="$1" partnum="$2"
  [ -z "$disk" -o -z "$partnum" ] && return

  if ! out=$(parted -sm "$disk" -- resizepart $partnum -1 2>&1); then
    echo "Unable to resize ${disk}${partnum}: ${out}"
    return 1
  fi
  udevadm settle
}

# Resizes partition by deleting and recreating with end position.
# This is a subshell function to safeguard against modifications of IFS.
parted_resize_mkpart() (
  local disk="$1" partnum="$2"
  [ -z "$disk" -o -z "$partnum" ] && return

  local partnum="" partbegin="" partend="" partsize=""
  local fstype="" partname="" flags="" temp=""

  # $ parted -sm /dev/sda unit b print
  # BYT;
  # /dev/sda:18253611008B:scsi:512:4096:msdos:Google PersistentDisk:;
  # 1:2097152B:18252611583B:18250514432B:ext4::boot;
  #
  if ! out=$(parted -sm "$disk" unit b print 2>&1); then
    echo "Unable to get partition info."
    return 1
  fi

  temp=/tmp/my_temp
  echo -e "$out" | sed '$!d' > $temp
  IFS=: read partnum partbegin partend partsize fstype partname flags < $temp
  rm $temp

  if ! out=$(parted -sm "$disk" rm $partnum 2>&1); then
    echo "Failed to delete partition: ${out}"
    return 1
  fi

  if ! out=$(parted -sm "$disk" -- mkpart pri $fstype $partbegin -1 2>&1); then
    echo "Failed to recreate original partition: ${out}"
    echo "Trying to create with original parameters."
    if ! out=$(parted -sm "$disk" mkpart pri $fstype $partbegin $partend 2>&1); then
      echo "Failed to recreate original partition: ${out}"
      return 1
    fi
  fi

  flags=${flags%%;}
  IFS=,
  for flag in $flags; do
    if ! out=$(parted -sm "$disk" set $partnum $flag on 2>&1); then
      echo "Failed to set \"$flag\" on ${disk} part ${partnum}: ${out}"
      return 1
    fi
  done
  udevadm settle
)
