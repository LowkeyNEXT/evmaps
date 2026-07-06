# StarPilot Galaxy EV Telemetry

Kia Maps can read a Galaxy JSON endpoint at `/api/vehicle/telemetry` from
the public Galaxy URL, for example `https://galaxy.firestar.link/<device-slug>`.
Use the QR-code URL from Galaxy pairing and the Galaxy session token shown in
StarPilot's App Keys screen.
The current StarPilot Galaxy portal exposes device, navigation, route, stats,
plot, and troubleshooting endpoints, but not a normalized EV battery endpoint.

The StarPilot schema already has the useful signals:

- `carState.fuelGauge`: battery or fuel tank level from `0.0` to `1.0`
- `carState.charging`: whether the vehicle is charging
- `carState.vEgo`: vehicle speed in meters per second
- `LastGPSPosition`: recent location from params

Add an endpoint like this near the other routes in
`starpilot/system/the_galaxy/the_galaxy.py`:

```python
@app.route("/api/vehicle/telemetry", methods=["GET"])
def get_vehicle_telemetry():
  sm = messaging.SubMaster(["carState"])
  sm.update(100)
  if not (sm.seen["carState"] and sm.alive["carState"] and sm.valid["carState"]):
    return jsonify({"error": "Waiting for live carState."}), 503

  car_state = sm["carState"]
  fuel_gauge = float(getattr(car_state, "fuelGauge", 0.0))
  state_of_charge_percent = max(0.0, min(100.0, fuel_gauge * 100.0))
  position = _get_navigation_last_position()

  return jsonify({
    "source": "StarPilot Galaxy",
    "updatedAt": time.time(),
    "vehicleName": "EV9",
    "stateOfChargePercent": state_of_charge_percent,
    "isCharging": bool(getattr(car_state, "charging", False)),
    "speedMetersPerSecond": float(getattr(car_state, "vEgo", 0.0)),
    "location": position,
  }), 200
```

Range is not a standard openpilot signal. If you want Maps range estimates from
Galaxy too, either add EV9/EGMP BMS parsing on the comma side or return an
estimated `estimatedRangeKilometers` from your own consumption model.
