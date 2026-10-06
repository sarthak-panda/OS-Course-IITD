#!/bin/bash
# smart_block_driver_test.sh
# Comprehensive test script for 2MB device with 100KB cache

print_disk_info() {
    echo "=== Disk Space Information ==="
    echo "Filesystem usage:"
    sudo df -h /mnt/smart_block
    echo "Backing file size: $(sudo stat -c %s /tmp/smart_block_backing) bytes"
    echo "Blocks available: $(sudo stat -f -c %a /mnt/smart_block) blocks"
    echo "Block size: $(sudo stat -f -c %S /mnt/smart_block) bytes"
    echo "Available space: $(( $(sudo stat -f -c %a /mnt/smart_block) * $(sudo stat -f -c %S /mnt/smart_block) )) bytes"
    echo "============================="
}

set -e

echo "=== Initializing Test Environment ==="
sudo umount /mnt/smart_block 2>/dev/null || true
sudo rmmod smart_block 2>/dev/null || true
sudo losetup -D

echo "Creating 2MB backing file..."
sudo dd if=/dev/zero of=/tmp/smart_block_backing bs=2M count=1 status=none

LOOP_DEV=$(sudo losetup -fP --show /tmp/smart_block_backing)
echo "Using loop device: $LOOP_DEV"

echo "Loading module with 100KB cache..."
sudo insmod smart_block.ko backing_file_path=$LOOP_DEV cache_size_bytes=100000

echo "Creating filesystem..."
sudo mkfs.ext2 -F /dev/smart_block

sudo mkdir -p /mnt/smart_block
sudo mount /dev/smart_block /mnt/smart_block
print_disk_info

# Test 1: Verify device capacity limits
echo -e "\n=== Test 1: Device Capacity Limits ==="
echo "Writing exact device capacity (2MB)..."
if sudo dd if=/dev/zero of=/mnt/smart_block/full_test bs=2M count=1 oflag=direct status=none; then
    echo "ERROR: Should not be able to write full device size due to filesystem overhead"
    exit 1
else
    echo "PASS: Got 'No space left on device' as expected"
fi

# Test 2: Cache overflow behavior
echo -e "\n=== Test 2: Cache Overflow Testing ==="
echo "flush" | sudo tee /proc/smart_block/flush > /dev/null
grep "Max" /proc/smart_block/stats
grep "Cache Used" /proc/smart_block/stats
echo "Initial writes to fill cache:"
sudo dd if=/dev/urandom of=/mnt/smart_block/overflow_test bs=90K count=1 oflag=direct status=none
echo "Cache usage after 90KB write:"
grep "Cache Used" /proc/smart_block/stats

echo "Writing 150KB to overflow 100KB cache:"
sudo dd if=/dev/urandom of=/mnt/smart_block/overflow_test bs=150K count=1 oflag=direct status=none
echo "Cache usage after overflow:"
grep "Cache Used" /proc/smart_block/stats
grep "Number of Writes Done To Disk" /proc/smart_block/stats

# Test 3: Manual flush functionality
echo -e "\n=== Test 3: Manual Cache Flush ==="
echo "flush" | sudo tee /proc/smart_block/flush > /dev/null
CACHE_AFTER_FLUSH=$(grep "Cache Used" /proc/smart_block/stats | awk '{print $3}')
[[ $CACHE_AFTER_FLUSH -eq 0 ]] && echo "PASS: Cache flushed" || echo "FAIL: Cache not flushed"

# Test 4: Dynamic cache adjustment
echo -e "\n=== Test 4: Dynamic Cache Sizing ==="
echo "Current max cache: $(grep 'Maximum size' /proc/smart_block/stats)"
echo "50000" | sudo tee /proc/smart_block/cache_size > /dev/null
echo "New cache size: $(grep 'Maximum size' /proc/smart_block/stats)"

# Test 5: Statistics validation
echo -e "\n=== Test 5: Statistics Reporting ==="
echo "Writing 50KB test pattern..."
sudo dd if=/dev/urandom of=/mnt/smart_block/stats_test bs=45K count=1 oflag=direct status=none
grep "Cache Used" /proc/smart_block/stats
REPORTED_USAGE=$(grep "Cache Used" /proc/smart_block/stats | awk '{print $3}')
[[ $REPORTED_USAGE -ge 49152 ]] && echo "PASS: Stats update correctly" || echo "FAIL: Stats mismatch"

# Test 6: Non-blocking writes(Not very correct)
echo -e "\n=== Test 6: Non-blocking Write Support ==="
echo "Testing non-blocking I/O (this should complete instantly)..."
sudo dd if=/dev/urandom of=/mnt/smart_block/nonblock_test bs=100K count=1 oflag=direct status=none

# Test 7: Data persistence
echo -e "\n=== Test 7: Data Persistence ==="
TEST_STR="PersistenceTest$(date +%s)"
echo "$TEST_STR" | sudo tee /mnt/smart_block/persistence_test > /dev/null
sync

echo "Reloading module..."
sudo umount /mnt/smart_block
sudo rmmod smart_block
sudo insmod smart_block.ko backing_file_path=$LOOP_DEV cache_size_bytes=100000
sudo mount /dev/smart_block /mnt/smart_block

[[ $(sudo cat /mnt/smart_block/persistence_test) == "$TEST_STR" ]] && echo "PASS: Data persisted" || echo "FAIL: Data loss"

# Cleanup
echo -e "\n=== Cleaning Up ==="
sudo umount /mnt/smart_block
sudo rmmod smart_block
sudo losetup -d $LOOP_DEV
echo "All tests completed successfully!"
