#!/bin/bash
# prepare-diff.sh — Extract git diff and build review context
# Usage: prepare-diff.sh [repo_path] [diff_range]
# Examples:
#   prepare-diff.sh ~/Documents/dec/firmware-pro2              # uncommitted changes
#   prepare-diff.sh ~/Documents/dec/firmware-pro2 HEAD~3..HEAD # last 3 commits
#   prepare-diff.sh ~/Documents/dec/firmware-pro2 main..feat/nfc

set -euo pipefail

REPO="${1:-.}"
RANGE="${2:-}"

# Validate repo path
if [ ! -d "$REPO" ]; then
    echo "ERROR: Directory not found: $REPO" >&2
    exit 1
fi

cd "$REPO"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: Not a git repository: $(pwd)" >&2
    exit 1
fi

# Use --no-pager to prevent hanging on interactive pagers
GIT="git --no-pager"

echo "=== REPO INFO ==="
echo "Path: $(pwd)"
echo "Branch: $($GIT branch --show-current 2>/dev/null || echo 'detached')"
echo "Last commit: $($GIT log -1 --oneline 2>/dev/null || echo 'none')"

echo ""
echo "=== TARGET IDENTIFICATION ==="
# Detect MCU/RTOS/compiler from build files (use find to avoid glob failures)
BUILD_FILES=$(find . -maxdepth 3 -name 'CMakeLists.txt' -o -name 'Makefile' -o -name '*.cmake' -o -name '*.mk' 2>/dev/null | head -20)
if [ -n "$BUILD_FILES" ]; then
    echo "$BUILD_FILES" | xargs grep -l "STM32\|nRF\|ESP32\|ATSAMD\|RP2040\|GD32\|CH32" 2>/dev/null | head -5 || true
    echo "$BUILD_FILES" | xargs grep -l "FreeRTOS\|Zephyr\|ThreadX\|CMSIS_RTOS\|RT-Thread" 2>/dev/null | head -3 || true
    echo "$BUILD_FILES" | xargs grep -l "arm-none-eabi\|armcc\|iccarm\|armclang" 2>/dev/null | head -3 || true
else
    echo "(No build files found)"
fi

# Collect diff
echo ""
echo "=== DIFF STAT ==="
if [ -n "$RANGE" ]; then
    $GIT diff --stat "$RANGE" 2>/dev/null
    DIFF=$($GIT diff "$RANGE" 2>/dev/null)
else
    # Check for staged + unstaged changes
    STAGED=$($GIT diff --cached --stat 2>/dev/null)
    UNSTAGED=$($GIT diff --stat 2>/dev/null)

    if [ -n "$STAGED" ] || [ -n "$UNSTAGED" ]; then
        if [ -n "$STAGED" ]; then
            echo "--- Staged ---"
            echo "$STAGED"
        fi
        if [ -n "$UNSTAGED" ]; then
            echo "--- Unstaged ---"
            echo "$UNSTAGED"
        fi
        DIFF="$($GIT diff --cached 2>/dev/null)
$($GIT diff 2>/dev/null)"
    else
        echo "(No uncommitted changes. Showing last commit diff)"
        $GIT diff HEAD~1 --stat 2>/dev/null || true
        DIFF=$($GIT diff HEAD~1 2>/dev/null || true)
    fi
fi

# Output line count for size assessment
LINE_COUNT=$(echo "$DIFF" | wc -l | tr -d ' ')
echo ""
echo "=== DIFF SIZE ==="
echo "Lines: $LINE_COUNT"
if [ "$LINE_COUNT" -le 100 ]; then
    echo "Assessment: SMALL (single-model recommended)"
elif [ "$LINE_COUNT" -le 500 ]; then
    echo "Assessment: MEDIUM"
else
    echo "Assessment: LARGE (review in batches by subsystem)"
fi

# Detect critical paths in changed files
CRITICAL=""
if echo "$DIFF" | grep -qiE '(IRQ|ISR|Handler|_IRQn|interrupt|DMA|dma_|HAL_DMA)'; then
    CRITICAL="${CRITICAL} ISR/DMA"
fi
if echo "$DIFF" | grep -qiE '(crypt|aes|sha|hmac|rng|trng|secure)'; then
    CRITICAL="${CRITICAL} CRYPTO"
fi
if echo "$DIFF" | grep -qiE '(nfc|nci|ndef|rfid|contactless|iso14443)'; then
    CRITICAL="${CRITICAL} NFC"
fi
if echo "$DIFF" | grep -qiE '(boot|bootloader|flash_write|flash_erase|OTA|fota)'; then
    CRITICAL="${CRITICAL} BOOT/OTA"
fi
if [ -n "$CRITICAL" ]; then
    echo "Critical paths detected:${CRITICAL}"
    echo "  → Dual-model cross-review recommended"
fi

echo ""
echo "=== DIFF ==="
echo "$DIFF"
