# 🛴 KS0193 — keyestudio Self-Balancing Car Kit

The keyestudio KS0193 self-balancing car, as a **workshop**: the vendor's manuals and
13 stock Arduino sketches, plus a teaching layer built on top of them — a guided
launcher that builds and flashes any lesson, and a single-page course that walks
through why each one exists.

The car is an Arduino UNO with a motor-driver shield, two encoder motors and an
MPU6050. Left alone it falls over. The 13 lessons are the path from *falls over* to
*stands up and drives*, one testable piece at a time.

---

## Repo map

| Path | What it is |
| --- | --- |
| `1.about keyestudio/` | Vendor company blurb (PDF) |
| `2.about this kit/` | The full kit manual — PDF and the original .docx |
| `3.Getting Started with Arduino/` | Vendor guides: installing the IDE, drivers, libraries |
| `4. Tutorial/` | **The working folder** — sketches, libraries, launcher, course |
| `Install Driver.pdf` | CH340/USB-serial driver instructions |

Inside `4. Tutorial/`:

| Path | What it is |
| --- | --- |
| `Test Code/01…13/` | The 13 lesson sketches, one folder each. Never modified by the build. |
| `Libraries/*.zip` | The four libraries the sketches need, bundled by keyestudio |
| `launch.sh` | Guided build / flash / monitor launcher |
| `workshop.html` | The course — open it in a browser, no server needed |
| `Bluetooth APP/` | `Balance_car_Keyes.apk`, the vendor Android remote |
| `.build/`, `.tools/` | Generated. Git-ignored. Safe to delete at any time. |

Everything under `1.`–`3.` and the PDFs, .docx, .apk and library zips are keyestudio's
own material, kept as shipped.

---

## Hardware

| | |
| --- | --- |
| Board | Arduino UNO — ATmega328P (`arduino:avr:uno`) |
| Motor driver | TB6612FNG — right `D8`/`D12`, PWM `D10`; left `D7`/`D6`, PWM `D9` |
| IMU | MPU6050 over I²C |
| Feedback | Hall encoders on both motors |
| Bluetooth | HC-06 on the **hardware** UART (`D0`/`D1`) |
| Also on board | Buzzer `D11`, button `D13` |
| Serial | 9600 baud — every lesson calls `Serial.begin(9600)` |

Motor power comes from the **battery pack**, not USB. With the pack off, a sketch runs
happily and the wheels stay dead.

---

## Quick start

Open a terminal on `4. Tutorial/` and run the launcher:

```bash
./launch.sh
```

It asks which lesson you want, then shows a menu:

```
0) Select lesson              5) Flash firmware        r) Show all the commands
1) Check installation         6) Build + Flash + Monitor   c) Toggle command echo
2) Install PlatformIO / arduino-cli  7) Serial monitor  t) Switch build backend
3) Prepare bundled libraries  8) List serial ports      q) Quit
4) Build firmware             9) Clean build
```

First time through: **1** to see what's missing, **2** to install a toolchain,
**3** to unpack the libraries, then **6** to build, flash and watch the output.

Either **PlatformIO** or **arduino-cli** works — the launcher finds whichever you have
and you can switch with `t`. `Test Code/` is only ever read; all build output lands in
`.build/`.

### Nothing here is magic

Every command is printed before it runs, and option **`r`** prints the *entire* recipe
for the selected lesson — install, unpack, compile, upload, monitor — without running
any of it. It is generated from the same variables the real actions use, so it cannot
drift out of date. Retype it, or save it and keep it.

### The course

`4. Tutorial/workshop.html` is the written workshop: four stages, a beginner/expert
toggle, and a simulator for the balance loop. Open it straight from disk.

---

## The 13 lessons

**Stage A — five things that must work before balancing is even thinkable**

| | Sketch | Proves |
| --- | --- | --- |
| 01 | `01_button_buzzer` | The board is alive and you can talk to it |
| 02 | `02_TB6612_motor` | Both motors turn, both directions |
| 03 | `03_hall_encoder` | The wheels can be *counted*, not just spun |
| 04 | `04_timer_interrupt` | A fixed 5 ms tick — the heartbeat every later loop needs |
| 05 | `05_Bluetooth` | Characters get in and out over the HC-06 |

**Stage B — from raw registers to an angle you can trust**

| | Sketch | Proves |
| --- | --- | --- |
| 06 | `06_MPU6050` | Raw accelerometer and gyroscope numbers arrive |
| 07 | `07_angle` | Those numbers become degrees — accurate but noisy, or smooth but drifting |
| 08 | `08_KalmanFilter` | One angle that is both. This is the number the car balances on. |

**Stage C — two nested loops, and the car comes alive**

| | Sketch | Proves |
| --- | --- | --- |
| 09 | `09_Upright_loop` | PD on the angle — it stands, then slowly runs away |
| 10 | `10_Speed_loop` | PI on the encoders, wrapped around the upright loop — it stays put |

**Stage D — putting a human in the loop**

| | Sketch | Proves |
| --- | --- | --- |
| 11 | `11_Bluetooth_control_1` | Drive and steer from the phone |
| 12 | `12_Bluetooth_adjust_angle___PID` | Retune the gains live, no reflash |
| 13 | `13_adjust_balance_angle_Bluetooth_control` | Trim the mechanical balance point — the finished car |

---

## Two things that will bite you

**Unplug the HC-06 before uploading.** It sits on `D0`/`D1`, the same hardware UART the
USB-serial chip uses. Left plugged in, the upload fails — usually as
`avrdude: stk500_getsync(): not in sync`. Plug it back in once the upload finishes. The
same collision means the serial monitor and the phone app can never both be connected;
lessons 05, 11, 12 and 13 are the ones affected.

**Hold the car still and upright at power-on.** `setup()` samples the MPU6050's gyro
offset during the first moments after reset. Move the car while that happens and the
offset is wrong, which poisons the balance point for the whole run — the car will drift
or lean and no amount of tuning will fix it until you reset it properly.

And from lesson 09 onward the motors spin the instant the board boots or resets. Put the
car on a stand, or hold it, before you flash.

---

## The bundled libraries

`Libraries/` holds four zips: `I2Cdev`, `MPU6050`, `MsTimer2`, `PinChangeInt-master`.
They are Arduino 1.0-format libraries with no `library.properties`, so the launcher
unpacks them into `.build/libraries/` and hands that to the compiler as an extra search
path rather than *installing* them into a sketchbook. Nothing is written outside
`.build/`, and your global Arduino setup is left alone.

One wrinkle: `PinChangeInt-master.zip` expands to a folder whose name no longer matches
its header, so it gets renamed to `PinChangeInt`. Both PlatformIO's dependency finder
and arduino-cli need that.

On Windows the launcher also deliberately uses very short generated paths
(`.build/13/src/sketch.ino`): the full lesson name pushes the compiler's object-file path
past the 260-character limit.

---

## Credits

The kit, the manuals, the sketches under `Test Code/`, the bundled libraries and the
Android app are **keyestudio's**, included as shipped.

The workshop layer — `launch.sh`, `workshop.html` and this README — is by
**Workshop-DIY**.
