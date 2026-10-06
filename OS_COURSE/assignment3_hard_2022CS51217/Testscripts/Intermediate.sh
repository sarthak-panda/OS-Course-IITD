#!/bin/bash
# smart_block_cache_resize_test.sh
# Test for dynamic cache resizing with detailed stats monitoring

print_disk_info() {
    echo -e "\n=== Disk Space Information ==="
    echo "Filesystem usage:"
    sudo df -h /mnt/smart_block
    echo "Backing file size: $(sudo stat -c %s /tmp/smart_block_backing) bytes"
    echo "Blocks available: $(sudo stat -f -c %a /mnt/smart_block) blocks"
    echo "Block size: $(sudo stat -f -c %S /mnt/smart_block) bytes"
    echo "Available space: $(( $(sudo stat -f -c %a /mnt/smart_block) * $(sudo stat -f -c %S /mnt/smart_block) )) bytes"
    echo "============================="
}

print_cache_stats() {
    echo -e "\n=== Cache Statistics ==="
    echo "Maximum cache size: $(grep 'Maximum size' /proc/smart_block/stats | awk '{print $3}') bytes"
    echo "Current cache usage: $(grep 'Cache Used' /proc/smart_block/stats | awk '{print $3}') bytes"
    echo "Writes to disk: $(grep 'Number of Writes Done To Disk' /proc/smart_block/stats | awk '{print $7}')"
    echo "============================="
}

set -eo pipefail

# Initialize environment
echo "=== Initializing Test Environment ==="
sudo umount /mnt/smart_block 2>/dev/null || true
sudo rmmod smart_block 2>/dev/null || true
sudo losetup -D
sync

echo "Creating 2MB backing file..."
dd if=/dev/zero of=/tmp/smart_block_backing bs=2M count=1 status=none

LOOP_DEV=$(sudo losetup -fP --show /tmp/smart_block_backing)
echo "Using loop device: $LOOP_DEV"

INITIAL_CACHE_SIZE=100000

echo "Loading module with ${INITIAL_CACHE_SIZE} bytes cache..."
sudo insmod smart_block.ko backing_file_path=$LOOP_DEV cache_size_bytes=$INITIAL_CACHE_SIZE

echo "Creating filesystem..."
sudo mkfs.ext4 -F /dev/smart_block

sudo mkdir -p /mnt/smart_block
sudo mount /dev/smart_block /mnt/smart_block

print_disk_info

generate_pattern() {
  local len=$1 out=''
  while (( ${#out} < len )); do
    chunk=$(head -c $(( (len - ${#out}) * 2 )) /dev/urandom \
            | tr -dc 'A-Za-z0-9')
    out+="$chunk"
  done
  echo "${out:0:len}"
}

# Test: Dynamic Cache Resizing Effects
echo -e "\n=== Test: Dynamic Cache Resizing Effects ==="

# Step 1: Flush cache and note initial stats
echo "Step 1: Flush cache and note initial stats"
echo "flush" | sudo tee /proc/smart_block/flush >/dev/null
echo "Initial cache stats after flush:"
print_cache_stats

# Step 2: Write 92KB of data
echo -e "\nStep 2: Writing 92KB data..."
TEST_FILE="/mnt/smart_block/resize_test"
DATA_SIZE=94208  # 92KB in bytes
TEST_DATA=$(generate_pattern $DATA_SIZE)

echo -n "$TEST_DATA" | sudo dd of="$TEST_FILE" bs=4096 oflag=direct status=none
WRITES_BEFORE=$(grep 'Number of Writes Done To Disk' /proc/smart_block/stats | awk '{print $7}')
CACHE_USED_BEFORE=$(grep 'Cache Used' /proc/smart_block/stats | awk '{print $3}')
TEST_SUM=$(echo -n "$TEST_DATA" | md5sum | awk '{print $1}')

echo "Data checksum: $TEST_SUM"
echo "Cache stats after 92KB write:"
print_cache_stats

# Step 3: Double the cache size and check stats
echo -e "\nStep 3: Doubling cache size..."
NEW_CACHE_SIZE=$((INITIAL_CACHE_SIZE * 2))
echo "$NEW_CACHE_SIZE" | sudo tee /proc/smart_block/cache_size >/dev/null

echo "Cache stats after doubling cache size:"
print_cache_stats

# Verify writes and cache used stayed the same
WRITES_AFTER=$(grep 'Number of Writes Done To Disk' /proc/smart_block/stats | awk '{print $7}')
CACHE_USED_AFTER=$(grep 'Cache Used' /proc/smart_block/stats | awk '{print $3}')

echo -e "\nVerification after cache expansion:"
if [[ "$WRITES_AFTER" -eq "$WRITES_BEFORE" ]]; then
  echo "PASS: Writes to device stayed same as expected"
else
  echo "FAIL: Writes to device increased"
  exit 1
fi

if [[ "$CACHE_USED_AFTER" -eq "$CACHE_USED_BEFORE" ]]; then
  echo "PASS: Cache usage remained constant as expected"
else
  echo "FAIL: Cache usage changed unexpectedly"
  exit 1
fi

# Verify data integrity after cache resize
FILE_SUM=$(sudo md5sum "$TEST_FILE" | awk '{print $1}')
if [[ "$FILE_SUM" == "$TEST_SUM" ]]; then
  echo "PASS: Data integrity preserved after cache expansion"
else
  echo "FAIL: Data integrity compromised after cache expansion"
  exit 1
fi

# Step 4: Reduce cache size to half of initial and check stats
echo -e "\nStep 4: Reducing cache size to half of initial..."
HALF_CACHE_SIZE=$((INITIAL_CACHE_SIZE / 2))
echo "$HALF_CACHE_SIZE" | sudo tee /proc/smart_block/cache_size >/dev/null

echo "Cache stats after reducing cache size:"
print_cache_stats

# Verify cache got flushed (used = 0)
CACHE_USED_FINAL=$(grep 'Cache Used' /proc/smart_block/stats | awk '{print $3}')

echo -e "\nVerification after cache reduction:"
if [[ "$CACHE_USED_FINAL" -eq 0 ]]; then
  echo "PASS: Cache was flushed when size was reduced"
else
  echo "FAIL: Cache was not flushed when size was reduced"
  exit 1
fi

# Verify data integrity after cache shrinking
FILE_SUM_AFTER=$(sudo md5sum "$TEST_FILE" | awk '{print $1}')
if [[ "$FILE_SUM_AFTER" == "$TEST_SUM" ]]; then
  echo "PASS: Data integrity preserved after cache reduction"
else
  echo "FAIL: Data integrity compromised after cache reduction"
  exit 1
fi

# Cleanup
echo -e "\n=== Cleaning Up ==="
sudo umount /mnt/smart_block
sudo rmmod smart_block
sudo losetup -d $LOOP_DEV
echo "Cache resize test completed successfully!"
