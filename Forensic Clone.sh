#!/bin/bash

# --- Forensic Clone Script for ShredOS ---

# 1. Setup Variables
SOURCE=/dev/nvme0n1        # Change this to your evidence drive
DEST=/dev/nvme1n1          # Change this to your target drive
USB_PATH="/mnt/usb"      # The mount point of your flash drive

echo "--- STARTING FORENSIC WORKFLOW ---"

# 2. Generate Source Hash
echo "[1/3] Hashing Source Drive ($SOURCE)..."
sha256sum $SOURCE | tee $USB_PATH/source_hash.txt

# 3. Perform Bit-for-Bit Clone
echo "[2/3] Cloning $SOURCE to $DEST..."
# We use bs=64K for speed and conv=noerror,sync for forensic integrity
dd if=$SOURCE of=$DEST bs=64K conv=noerror,sync status=progress

# 4. Generate Destination Hash for Verification
echo "[3/3] Hashing Destination Drive ($DEST)..."
sha256sum $DEST | tee $USB_PATH/destination_hash.txt

# 5. Final Comparison
echo "--- VERIFICATION ---"
if diff $USB_PATH/source_hash.txt $USB_PATH/destination_hash.txt; then
    echo "SUCCESS: Hashes match! The clone is bit-perfect."
else
    echo "ERROR: Hashes do not match! Check for hardware errors."
fi
