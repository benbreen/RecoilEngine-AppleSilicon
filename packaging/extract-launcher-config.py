#!/usr/bin/env python3
"""Extract deploy artifacts from BAR's canonical launcher config (the same file
spring-launcher consumes) so the Mac launcher stays faithful to BAR instead of
hardcoding values. Run at BUILD time (a user's Mac may lack python3).

Produces, into the output dir:
  chobby_config.json            <- config['json_files']['chobby_config.json']
  default_springsettings.cfg    <- config['default_springsettings'] as Key=Value
                                   (minus keys the Mac launcher owns: display)

Usage: extract-launcher-config.py <dist_cfg/config.json> <out-dir>
"""
import json, sys, os

# Display/window keys are owned by the Mac launcher (windowed-first, retina,
# our perf-tuned present) — never take BAR's fullscreen/geometry defaults.
OWNED = {
    "Fullscreen", "WindowBorderless", "WindowPosX", "WindowPosY",
    "XResolutionWindowed", "YResolutionWindowed", "XResolution", "YResolution",
    "VSyncGame",
}

def main():
    cfg_path, out_dir = sys.argv[1], sys.argv[2]
    cfg = json.load(open(cfg_path))
    os.makedirs(out_dir, exist_ok=True)

    jf = cfg.get("json_files", {}).get("chobby_config.json")
    if jf is None:
        print("FATAL: dist_cfg has no json_files.chobby_config.json", file=sys.stderr)
        sys.exit(1)
    with open(os.path.join(out_dir, "chobby_config.json"), "w") as f:
        json.dump(jf, f, indent=2)

    ss = cfg.get("default_springsettings", {})
    with open(os.path.join(out_dir, "default_springsettings.cfg"), "w") as f:
        for k in sorted(ss):
            if k in OWNED:
                continue
            v = ss[k]
            if isinstance(v, bool):
                v = 1 if v else 0
            f.write(f"{k} = {v}\n")

    print(f"extracted chobby_config.json + {sum(1 for k in ss if k not in OWNED)} "
          f"default springsettings (excluded {len(OWNED & set(ss))} display keys)")

if __name__ == "__main__":
    main()
