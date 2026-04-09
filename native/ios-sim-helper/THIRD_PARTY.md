# Third-party / reverse-engineered pieces

- **`Indigo.h` / `Mach.h`** — Derived from Meta [idb](https://github.com/facebook/idb) `PrivateHeaders/SimulatorApp/` (MIT License). Describes the Indigo HID wire format used between host and Simulator.
- **`SimulatorIndigoTouch.m`** — Touch message layout and flow adapted from idb `FBSimulatorIndigoHID.m` (MIT).
- **Runtime use** — Loads Apple’s private frameworks `CoreSimulator` and `SimulatorKit` from the active Xcode / system paths. This can break on Xcode updates; not covered by any public Apple API contract.
