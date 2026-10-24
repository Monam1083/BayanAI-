# BayanAI

A voice-controlled khata and stock app for small Karyana shopkeepers. Instead of writing in a paper notebook, the owner taps a button and speaks:

> "Ahmad took 500 rupees of sugar on credit" / "احمد نے پانچ سو روپے کی چینی ادھار لی" / "Ahmad ne 200 rupay wapas diye"

The app shows what it understood, the owner taps **Save**, and the customer's balance and the stock update instantly.

## How it works

```
 Flutter app ──record──► AI service (your laptop) ──────────────► Flutter app
 (phone)        WAV      1. faster-whisper: speech → text         shows a confirm card
     │                   2. Ollama (open LLM): text → JSON            │ tap Save
     │                      {action, customer, item, qty, amount}     ▼
     └──────────────────────── Firebase (Auth + Firestore) ◄──── balance and stock update live
```

| Part | Folder | Tech |
|---|---|---|
| Mobile app | `flutter_app/` | Flutter, Firebase Auth (anonymous), Cloud Firestore |
| AI service | `ai_service/` | Python, FastAPI, faster-whisper, Ollama |
| Security rules | `firebase/firestore.rules` | Each user can only touch `shops/{their uid}` |

### Open-source AI used
- **Whisper** (through `faster-whisper`) for speech to text, Urdu supported.
- **An open LLM served by Ollama** (default `qwen2.5:7b`, change with `OLLAMA_MODEL`) to turn the text into structured commands.

Everything runs on your own machine. No audio or shop data goes to a paid AI API.

### What the voice commands do

| Action | Example | Effect |
|---|---|---|
| `credit` | "Bilal took 2 kilo rice on credit, 600 rupees" | Bilal's balance +600, rice stock −2 kg |
| `payment` | "Ahmad paid back 200 rupees" | Ahmad's balance −200 |
| `sale` | "Sold 10 kilo flour" | flour stock −10 kg |
| `restock` | "Add 50 packets of tea to stock" | tea stock +50 packets |

If only money is said ("500 rupees of sugar on credit"), the balance changes but the stock does not, because no quantity was heard. One sentence can contain several commands.

Names are matched loosely ("Ahmed" finds "Ahmad"); a new name creates a new customer. Roman Urdu product names are mapped to one English name (cheeni → sugar, chawal → rice) so stock stays in one line per product.

## Setup

### 1. Firebase (about 5 minutes)
1. Create a project at <https://console.firebase.google.com>.
2. **Authentication → Sign-in method → Anonymous → Enable.**
3. **Firestore Database → Create database.**
4. **Firestore → Rules:** paste the contents of `firebase/firestore.rules` and publish.

### 2. AI service (on the laptop that will run the demo)
```bash
# Install Ollama from https://ollama.com, then:
ollama pull qwen2.5:7b          # weak laptop? use qwen2.5:3b and set OLLAMA_MODEL below

cd ai_service
python -m venv .venv
source .venv/bin/activate       # Windows: .venv\Scripts\activate
pip install -r requirements.txt

uvicorn main:app --host 0.0.0.0 --port 8000
```
Optional settings (environment variables): `OLLAMA_MODEL`, `OLLAMA_URL`, `WHISPER_MODEL` (`small` default; `medium` is better for Urdu but slower, `base` is faster and less accurate), `WHISPER_LANGUAGE` (`ur` default, `en`, or `auto`).
Example: `export WHISPER_MODEL=medium` (PowerShell: `$env:WHISPER_MODEL="medium"`).

> Run it once **before the event**. Whisper downloads its model on first start and Ollama downloads the LLM on `pull`; do not rely on venue Wi-Fi for that.

Check it: open `http://localhost:8000/health` in a browser. `"ollama": true` means it is ready.

### 3. Flutter app
```bash
cd flutter_app
flutter create --project-name bayanai .   # generates android/ and ios/ (your lib/ and pubspec.yaml are kept)
# then delete test/widget_test.dart: the generated sample test does not match this app

dart pub global activate flutterfire_cli
flutterfire configure            # pick your Firebase project; this replaces lib/firebase_options.dart

flutter pub get
flutter run
```
If `flutter pub get` complains about version conflicts, run `flutter pub upgrade --major-versions`.

**Android settings** (`android/app/src/main/AndroidManifest.xml`):
- inside `<manifest>` add
  `<uses-permission android:name="android.permission.RECORD_AUDIO"/>` and
  `<uses-permission android:name="android.permission.INTERNET"/>`
- on the `<application ...>` tag add `android:usesCleartextTraffic="true"` (the AI service uses plain http on your local network)
- in `android/app/build.gradle` (or `.kts`) set `minSdk` to `23`

**iOS settings** (`ios/Runner/Info.plist`): add `NSMicrophoneUsageDescription` (any text), `NSLocalNetworkUsageDescription`, and under `NSAppTransportSecurity` set `NSAllowsLocalNetworking` to `true`.

### 4. Connect the phone to the AI service
Tap the **gear icon** in the app, enter the service address, press **Test**, then **Save**.

| Situation | Address |
|---|---|
| Android emulator | `http://10.0.2.2:8000` (default) |
| Real phone, same Wi-Fi as the laptop | `http://<laptop IP>:8000` (find the IP with `ipconfig` / `ip a`) |
| Real Android phone on USB | run `adb reverse tcp:8000 tcp:8000`, then `http://127.0.0.1:8000` |

Event Wi-Fi often blocks devices from talking to each other. If **Test** fails, use your phone's hotspot for the laptop, or the USB option. The first time, allow Python through the laptop firewall.

## Using the app
- **Tap to speak** → say a command → tap again to stop.
- A card shows what was heard and understood. Fix the text and tap the refresh icon if it is wrong, remove a wrong card with ✕, then **Save**. Nothing is written until you save.
- The keyboard button types a command instead (also the fallback if the microphone or Urdu recognition misbehaves).
- Tabs: **Khata** (customers and who owes what), **Stock**, **History**. Tap a customer to see their own history.

Good demo phrases:
1. "Ahmad took 500 rupees of sugar on credit"
2. "Bilal ne 2 kilo chawal udhaar liye, 600 rupay"
3. "Ahmad ne 200 rupay wapas diye"
4. "Add 50 kilo rice to stock", then "Sold 10 kilo rice"

## Tests

```bash
cd ai_service
pip install -r requirements-dev.txt
pytest
```
These cover the cleaning and validation of model output and the API endpoints, with the speech model and Ollama replaced by fakes. They do not measure how well your chosen models understand real Urdu speech; test that with your own recordings.

## Data layout (Firestore)
```
shops/{uid}/customers/{id}     name, balance, createdAt
shops/{uid}/items/{id}         name, quantity, unit, createdAt
shops/{uid}/transactions/{id}  action, customerId, customerName, itemName, quantity, unit, amount, transcript, createdAt
```
Balances and stock use atomic increments, and every command is saved as one batch.

## Known limits
- Login is anonymous, so a shop's data belongs to that app install. Uninstalling loses access. Add phone or email login for real use.
- The AI service has no password; anyone on the same network can call it. Fine for a demo, not for deployment.
- Saved entries cannot be edited or undone yet; the confirm card is the safety net.
- Speech recognition on noisy shop audio and mixed Urdu/English can be wrong, which is why every command is confirmed before saving.

## License
MIT. See `LICENSE`.
