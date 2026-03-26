# Optimise BPoint biller code storage — remove redundant prefix

**What changes**

All ~700 biller codes are 7-digit numbers starting with `"100"`. Right now every single code is stored as a full string like `"1001020"`, `"1000056"`, etc. — wasting space and hiding the pattern.

**Optimisation**

- **Store only the unique 4-digit suffixes as integers** (e.g. `1020`, `56`, `3005`) in a compact `[Int]` array
- **Define the common prefix `"100"` as a single constant** next to the suffix array
- **Reconstruct full codes on the fly** by formatting: `prefix + String(format: "%04d", suffix)` → `"1001020"`
- The existing `allBillerCodes: [String]` computed property stays identical from the outside — all consumers (`getRandomActiveBiller`, blacklist logic, UI counts, etc.) continue working with full 7-digit strings without any changes
- The blacklist storage (UserDefaults) still persists full codes so existing user data isn't broken
- No changes to any views, the automation engine, or the pool management screen — only the internal storage of the master list changes

**Result**

- ~2,100 fewer characters of hardcoded string data
- The shared prefix pattern is explicit and documented in one place
- Everything else in the app stays untouched

