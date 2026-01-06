# Agent Reporting Mechanism - Detailed Explanation

## Overview
The agent runs **every 1 minute** via Windows Task Scheduler as the SYSTEM account. It collects system data and sends it to your web app via HTTP POST requests.

---

## 📊 How Often Does It Send Data?

### Base Frequency: **Every 1 Minute**
- The scheduled task triggers `Agent.ps1` every 60 seconds
- However, **adaptive polling** can reduce this frequency when the PC is idle

### Actual Send Frequency Depends On:
1. **PC Activity Status** (idle vs active)
2. **Time Since Last Successful Send**
3. **Network Connectivity**

---

## ⚙️ What Affects the Intervals?

### 1. **Adaptive Polling Logic** (Lines 179-199 in Agent.ps1)

The agent uses **smart polling** to reduce unnecessary API calls:

**Configuration Constants:**
- `$AdaptivePollingThreshold = 600` seconds (10 minutes)
- `$AdaptivePollingInterval = 300` seconds (5 minutes)

**How It Works:**

```
IF idleTimeSeconds > 600 (10 minutes) AND
   lastSendTime exists AND
   timeSinceLastSend < 300 (5 minutes)
THEN
   SKIP this heartbeat (don't send)
ELSE
   SEND heartbeat normally
```

**Example Scenarios:**

| Scenario | Idle Time | Last Send | Action |
|----------|-----------|-----------|--------|
| Active PC | 2 minutes | 1 min ago | ✅ **SEND** (normal) |
| Just went idle | 11 minutes | 1 min ago | ✅ **SEND** (first idle report) |
| Still idle | 15 minutes | 2 min ago | ❌ **SKIP** (too soon) |
| Still idle | 20 minutes | 6 min ago | ✅ **SEND** (5 min passed) |
| User returned | 0 seconds | 2 min ago | ✅ **SEND** (back to active) |

### 2. **Network Failures**

If the API request fails:
- The payload is **queued** to `C:\ProgramData\MyAgent\queue.jsonl`
- The agent continues running every minute
- On the next successful connection, **all queued items are sent**

---

## 🔄 What Happens When Idle Time Exceeds 10 Minutes?

### When PC Becomes Idle (> 10 minutes):

1. **First Idle Report** (immediate):
   - Agent detects `idleTimeSeconds > 600`
   - Sends heartbeat with high idle time
   - Records timestamp in `last_send.txt`

2. **Subsequent Runs** (every minute):
   - Agent checks: "Is idle > 10 min AND last send < 5 min ago?"
   - If YES → **Skips sending** (saves API calls)
   - If NO → **Sends heartbeat** (5 minutes have passed)

3. **Result:**
   - Instead of sending every 1 minute, it sends **every 5 minutes** when idle
   - Reduces server load by 80% during idle periods
   - Still maintains regular updates (every 5 min)

### Example Timeline (PC Idle for 30 minutes):

```
Time    | Idle Time | Last Send | Action
--------|----------|-----------|--------
00:00   | 11 min   | Never     | ✅ SEND (first idle report)
00:01   | 12 min   | 1 min ago | ❌ SKIP (too soon)
00:02   | 13 min   | 1 min ago | ❌ SKIP (too soon)
00:03   | 14 min   | 1 min ago | ❌ SKIP (too soon)
00:04   | 15 min   | 1 min ago | ❌ SKIP (too soon)
00:05   | 16 min   | 5 min ago | ✅ SEND (5 min passed)
00:06   | 17 min   | 1 min ago | ❌ SKIP (too soon)
...
00:10   | 21 min   | 5 min ago | ✅ SEND (5 min passed)
```

---

## 🎯 What Happens When PC Is No Longer Idle?

### When User Returns (idle time drops below 10 minutes):

1. **Immediate Detection:**
   - Next run (within 1 minute) detects `idleTimeSeconds ≤ 600`
   - Adaptive polling check **fails** (idle ≤ threshold)
   - **Normal polling resumes immediately**

2. **Behavior:**
   - Returns to sending **every 1 minute**
   - No delay or waiting period
   - First heartbeat after return shows `idleTimeSeconds = 0` (or low value)

3. **Example Timeline:**

```
Time    | Idle Time | Last Send | Action
--------|----------|-----------|--------
00:00   | 25 min   | 2 min ago | ❌ SKIP (adaptive polling)
00:01   | 0 sec    | 2 min ago | ✅ SEND (user returned!)
00:02   | 0 sec    | 1 min ago | ✅ SEND (normal polling)
00:03   | 30 sec   | 1 min ago | ✅ SEND (normal polling)
```

**Key Point:** The agent **immediately** resumes normal frequency when activity is detected. There's no delay or "warm-up" period.

---

## 📦 What Does the Data Look Like?

### JSON Payload Structure

Every heartbeat sends a JSON object with these fields:

```json
{
  "computerId": "20E47205-844A-11EA-80DC-002B6735BC59",
  "computerName": "SAM",
  "username": "samsa",
  "online": true,
  "pcStatus": "on",
  "pcUptime": "02:05:30:15",
  "idleTimeSeconds": 0,
  "timestamp": "2026-01-06T12:49:24.1234567Z"
}
```

### Field Descriptions:

| Field | Type | Description | Example Values |
|-------|------|-------------|----------------|
| `computerId` | string | Hardware UUID (unique per PC, persists through renames) | `"20E47205-844A-11EA-80DC-002B6735BC59"` |
| `computerName` | string | Windows computer name | `"SAM"`, `"DESKTOP-ABC123"` |
| `username` | string | Current logged-in user | `"samsa"`, `"Administrator"` |
| `online` | boolean | Always `true` for heartbeats | `true` |
| `pcStatus` | string | Always `"on"` for heartbeats | `"on"` |
| `pcUptime` | string | System uptime formatted as `HH:mm:ss` (< 24h) or `DD:HH:mm:ss` (≥ 24h) | `"05:23:45"` or `"02:05:23:45"` |
| `idleTimeSeconds` | integer | Seconds since last user input (keyboard/mouse) | `0` (active), `600` (10 min idle), `3600` (1 hour idle) |
| `timestamp` | string | ISO 8601 UTC timestamp when payload was created | `"2026-01-06T12:49:24.1234567Z"` |

### Example Payloads:

**Active PC (just used):**
```json
{
  "computerId": "20E47205-844A-11EA-80DC-002B6735BC59",
  "computerName": "SAM",
  "username": "samsa",
  "online": true,
  "pcStatus": "on",
  "pcUptime": "00:02:15:30",
  "idleTimeSeconds": 5,
  "timestamp": "2026-01-06T12:49:24.1234567Z"
}
```

**Idle PC (15 minutes idle):**
```json
{
  "computerId": "20E47205-844A-11EA-80DC-002B6735BC59",
  "computerName": "SAM",
  "username": "samsa",
  "online": true,
  "pcStatus": "on",
  "pcUptime": "00:02:20:45",
  "idleTimeSeconds": 900,
  "timestamp": "2026-01-06T12:50:24.1234567Z"
}
```

**PC Just Returned from Idle:**
```json
{
  "computerId": "20E47205-844A-11EA-80DC-002B6735BC59",
  "computerName": "SAM",
  "username": "samsa",
  "online": true,
  "pcStatus": "on",
  "pcUptime": "00:02:21:00",
  "idleTimeSeconds": 0,
  "timestamp": "2026-01-06T12:51:24.1234567Z"
}
```

### HTTP Request Details:

**Method:** `POST`  
**URL:** Your configured API endpoint (from registry)  
**Headers:**
```
Content-Type: application/json
X-API-KEY: <your-api-key>
```
**Body:** Compressed JSON (single line, no formatting)

---

## 🔍 How to Verify Agent Status

Run the included `check-agent-status.ps1` script to see:
- Scheduled task status
- Last send time
- Queue status (pending items)
- Recent errors
- Current system state
- Adaptive polling status

**Current Status (from your PC):**
- ✅ Last send: 3 minutes ago
- ✅ Queue: Empty (all data sent successfully)
- ✅ No errors logged
- ✅ System active (0 seconds idle)
- ✅ Adaptive polling: Inactive (normal frequency)

---

## 📈 Summary Table

| Condition | Send Frequency | Notes |
|-----------|---------------|-------|
| **Active PC** (idle ≤ 10 min) | Every **1 minute** | Normal operation |
| **Idle PC** (idle > 10 min) | Every **5 minutes** | Adaptive polling active |
| **Network Failure** | Queued, sent on reconnect | No data loss |
| **User Returns** | Immediately resumes **1 minute** | No delay |

---

## 🛡️ Reliability Features

1. **Offline Queuing:** Failed requests saved to `queue.jsonl` (max 10MB)
2. **Batch Processing:** Queued items sent in batches of 50
3. **Error Logging:** All errors logged to `error.log`
4. **Registry Config:** API URL and key stored securely in HKLM registry
5. **SYSTEM Account:** Runs with elevated privileges, survives user logouts

---

## 💡 Key Takeaways

1. **Base frequency:** Every 1 minute
2. **Idle optimization:** Reduces to every 5 minutes when idle > 10 min
3. **Immediate resume:** Returns to 1-minute frequency as soon as user is active
4. **No data loss:** Failed requests are queued and retried
5. **Efficient:** Uses native .NET APIs, minimal CPU overhead

