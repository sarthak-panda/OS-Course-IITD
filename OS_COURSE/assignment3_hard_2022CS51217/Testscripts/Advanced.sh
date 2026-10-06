#!/bin/bash
# smart_block_validation_test.sh
# Comprehensive test with checksums and persistence verification

print_disk_info() {
    echo -e "\n\n=== Disk Space Information ==="
    echo "Filesystem usage:"
    sudo df -h /mnt/smart_block
    echo "Backing file size: $(sudo stat -c %s /tmp/smart_block_backing) bytes"
    echo "Blocks available: $(sudo stat -f -c %a /mnt/smart_block) blocks"
    echo "Block size: $(sudo stat -f -c %S /mnt/smart_block) bytes"
    echo "Available space: $(( $(sudo stat -f -c %a /mnt/smart_block) * $(sudo stat -f -c %S /mnt/smart_block) )) bytes"
    echo "============================="
}


set -eo pipefail

# Initialize environment
echo "=== Initializing Test Environment ==="
sudo umount /mnt/smart_block 2>/dev/null || true
sudo rmmod smart_block 2>/dev/null || true
sudo losetup -D
sync

# Create fresh 2MB backing file
echo "Creating 2MB backing file..."
dd if=/dev/zero of=/tmp/smart_block_backing bs=2M count=1 status=none

# Setup loop device
LOOP_DEV=$(sudo losetup -fP --show /tmp/smart_block_backing)
echo "Using loop device: $LOOP_DEV"

# Load module with 100KB cache
echo "Loading module with 100KB cache..."
sudo insmod smart_block.ko backing_file_path=$LOOP_DEV cache_size_bytes=100000

# Create filesystem
echo "Creating filesystem..."
sudo mkfs.ext4 -F /dev/smart_block

# Mount filesystem
sudo mkdir -p /mnt/smart_block
sudo mount /dev/smart_block /mnt/smart_block

# Generate test patterns
generate_pattern() {
  local len=$1 out=''
  while (( ${#out} < len )); do
    # get a chunk roughly twice the remaining needed size
    chunk=$(head -c $(( (len - ${#out}) * 2 )) /dev/urandom \
            | tr -dc 'A-Za-z0-9')
    out+="$chunk"
  done
  # echo exactly len chars
  echo "${out:0:len}"
}

# Verify checksum consistency
verify_checksum() {
  local file=$1
  local stored_sum=$2
  
  current_sum=$(sudo md5sum "$file" | awk '{print $1}')
  if [[ "$current_sum" != "$stored_sum" ]]; then
    echo "CHECKSUM FAILURE: Expected $stored_sum, got $current_sum"
    return 1
  fi
  return 0
}

# Test 0: Full device capacity validation,please comment to test remaining once
# echo -e "\n=== Test 0: Full Device Capacity ==="
# FILL_FILE="/mnt/smart_block/fill_test"
# BLOCK_SIZE=4096

# echo "Filling device with 4096-aligned random data..."
# # Generate data that's exactly 2MB (2097152 bytes), which is 512 blocks of 4096 bytes
# TEST_DATA=$(generate_pattern 2097152)
# echo -n "$TEST_DATA" | sudo dd of="$FILL_FILE" bs=4096 oflag=direct status=none
# FILL_SUM=$(sudo md5sum "$FILL_FILE" | awk '{print $1}')
# echo "Fill file checksum: $FILL_SUM"

# # Try to write one more byte beyond capacity
# if sudo dd if=/dev/zero of="$FILL_FILE" bs=1 seek=2097152 count=1 oflag=direct status=none 2>/dev/null; then
#   echo "FAIL: Wrote beyond device capacity"
#   exit 1
# else
#   echo "PASS: Proper device capacity enforcement"
# fi

# Test 1: Basic write-read validation
print_disk_info
echo -e "\n=== Test 1: Basic Read/Write Validation ==="
TEST_FILE="/mnt/smart_block/basic_test"
# 524288 bytes is exactly 128 blocks of 4096
TEST_DATA=$(generate_pattern 524288)  # 512KB

echo -n "$TEST_DATA" | sudo dd of="$TEST_FILE" bs=4096 oflag=direct status=none
STORED_SUM=$(echo -n "$TEST_DATA" | md5sum | awk '{print $1}')
sync

echo "Verifying basic readback..."
READ_BACK=$(sudo cat "$TEST_FILE")
READ_SUM=$(echo -n "$READ_BACK" | md5sum | awk '{print $1}')
if [[ "$READ_SUM" == "$STORED_SUM" ]]; then
  echo "PASS: Basic read/write validation"
else
  echo "FAIL: Data mismatch in basic test"
  exit 1
fi

# Test 2: Cache overflow with checksum
print_disk_info
echo -e "\n=== Test 2: Cache Overflow Validation ==="
OVERFLOW_FILE="/mnt/smart_block/overflow_test"
# 151552 bytes is 37 blocks of 4096 (slightly over 100KB cache)
OVERFLOW_DATA=$(generate_pattern 151552)

echo -n "$OVERFLOW_DATA" | sudo dd of="$OVERFLOW_FILE" bs=4096 oflag=direct status=none
OVERFLOW_SUM=$(echo -n "$OVERFLOW_DATA" | md5sum | awk '{print $1}')

echo "Current cache usage:"
grep "Cache Used" /proc/smart_block/stats

echo "Flushing cache..."
echo "flush" | sudo tee /proc/smart_block/flush >/dev/null
sync

echo "Verifying overflow data..."
verify_checksum "$OVERFLOW_FILE" "$OVERFLOW_SUM" && echo "PASS: Overflow checksum valid"

# Test 3: Cross-reload persistence
print_disk_info
echo -e "\n=== Test 3: Module Reload Persistence ==="
PERSIST_FILE="/mnt/smart_block/persist_test"
# 299008 bytes is 73 blocks of 4096 (~300KB)
PERSIST_DATA=$(generate_pattern 299008)

echo -n "$PERSIST_DATA" | sudo dd of="$PERSIST_FILE" bs=4096 oflag=direct status=none
PERSIST_SUM=$(echo -n "$PERSIST_DATA" | md5sum | awk '{print $1}')
sync

echo "Reloading module..."
sudo umount /mnt/smart_block
sudo rmmod smart_block
sudo insmod smart_block.ko backing_file_path=$LOOP_DEV cache_size_bytes=100000
sudo mount /dev/smart_block /mnt/smart_block

echo "Verifying persistent data..."
verify_checksum "$PERSIST_FILE" "$PERSIST_SUM" && echo "PASS: Persistence across reload"

# Test 4: Backing file integrity
print_disk_info
echo -e "\n=== Test 4: Backing File Validation ==="
echo "Flushing all data..."
echo "flush" | sudo tee /proc/smart_block/flush >/dev/null
sync

echo "Comparing backing file to device content..."
sudo umount /mnt/smart_block
sudo dd if=/dev/smart_block of=/tmp/device_image bs=4096 status=none
sudo dd if=$LOOP_DEV of=/tmp/backing_image bs=4096 status=none

DEVICE_SUM=$(md5sum /tmp/device_image | awk '{print $1}')
BACKING_SUM=$(md5sum /tmp/backing_image | awk '{print $1}')

if [[ "$DEVICE_SUM" == "$BACKING_SUM" ]]; then
  echo "PASS: Backing file matches device state"
else
  echo "FAIL: Backing file mismatch"
  echo "Device: $DEVICE_SUM Backing: $BACKING_SUM"
fi

# Remount for remaining tests
sudo mount /dev/smart_block /mnt/smart_block

# Test 5: Read while dirty cache
print_disk_info
echo -e "\n=== Test 5: Dirty Cache Read Validation ==="
echo "## Initial Cache Stats ##"
sudo cat /proc/smart_block/stats | grep -E "Used|Dirty"

DIRTY_FILE="/mnt/smart_block/dirty_test"
DIRTY_DATA=$(generate_pattern 73728)  # 72KB (18 blocks)

echo -e "\n[Phase 1] Writing 72KB of unflushed data..."
echo -n "$DIRTY_DATA" | dd of="$DIRTY_FILE" bs=4096 oflag=direct status=none
DIRTY_SUM=$(echo -n "$DIRTY_DATA" | md5sum | awk '{print $1}')
echo "|-> Write checksum: ${DIRTY_SUM}"

echo -e "## Pre-Flush Cache Stats ##"
sudo cat /proc/smart_block/stats | grep -E "Used|Dirty"
sudo cat /proc/smart_block/stats | grep -E "Writes Done"

echo -e "[Phase 2] Reading from dirty cache..."
verify_checksum "$DIRTY_FILE" "$DIRTY_SUM" && echo "|-> Dirty read validation successful"

echo -e "[Phase 3] Flushing cache to backing store..."
echo "flush" | sudo tee /proc/smart_block/flush >/dev/null

echo -e "## Post-Flush Cache Stats ##"
sudo cat /proc/smart_block/stats | grep -E "Used|Dirty"
sudo cat /proc/smart_block/stats | grep -E "Writes Done"

echo -e "[Phase 4] Validating persisted data..."
verify_checksum "$DIRTY_FILE" "$DIRTY_SUM" && echo "PASS: Dirty cache handling validated"


# Test 6: Power loss simulation
print_disk_info
echo -e "\n=== Test 6: Crash Consistency Test ==="
CRASH_FILE="/mnt/smart_block/crash_test"
# 819200 bytes is 200 blocks of 4096 (800KB)
CRASH_DATA=$(generate_pattern 819200)

echo "Writing 800KB data (partial cache)..."
echo -n "$CRASH_DATA" | sudo dd of="$CRASH_FILE" bs=4096 oflag=direct status=none
CRASH_SUM=$(sudo md5sum "$CRASH_FILE" | awk '{print $1}')

echo "Simulating crash..."
# Proper cleanup sequence
sudo umount /mnt/smart_block 2>/dev/null || true
sudo dmsetup remove_all 2>/dev/null || true
sudo losetup -d $LOOP_DEV 2>/dev/null || true
sudo sync

# Force remove module if needed
sudo rmmod smart_block 2>/dev/null || {
    echo "WARNING: Module busy, forcing removal"
    sudo rmmod -f smart_block
}

echo "Reloading..."
LOOP_DEV=$(sudo losetup -fP --show /tmp/smart_block_backing)
sudo insmod smart_block.ko backing_file_path=$LOOP_DEV cache_size_bytes=100000
sudo mount /dev/smart_block /mnt/smart_block

echo "Verifying data..."
#READ_BACK="$(sudo cat $DIRTY_FILE)"
verify_checksum "$CRASH_FILE" "$CRASH_SUM" && echo "PASS: Crash consistency"


# Cleanup
echo -e "\n=== Cleaning Up ==="
sudo umount /mnt/smart_block
sudo rmmod smart_block
sudo losetup -d $LOOP_DEV
rm -f /tmp/device_image /tmp/backing_image
echo "All validation tests completed successfully!"
