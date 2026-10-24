"""Turns raw language-model output into clean, validated shop commands.

Nothing in this file touches the network or loads a model, so it can be tested
quickly (see test_parsing.py).
"""

from __future__ import annotations

import json
from typing import Literal, Optional

from pydantic import BaseModel, ValidationError, field_validator

Action = Literal["credit", "payment", "sale", "restock"]

SYSTEM_PROMPT = """\
You extract shop-ledger commands from what a Pakistani Karyana (grocery store) \
shopkeeper said. The text may be Urdu script, Roman Urdu, English, or a mix, \
and it may contain speech-recognition mistakes.

Reply with JSON only, in exactly this shape:
{"commands": [ {command}, ... ]}
Use one command per distinct action. If the text contains no shop action, \
reply {"commands": []}.

Each command has these fields:
- "action": one of
    "credit"  a customer took goods and will pay later (udhaar, ادھار, \
khate mein likh do, on credit)
    "payment" a customer paid money back (wapas diye, ada kiye, jama karwaye, \
ادا کیے, paid back)
    "sale"    goods sold for cash with no credit (bech diya, sold)
    "restock" the shopkeeper got more goods (maal aaya, stock mein add karo, \
added to stock)
- "customer": the person's name written in English letters (for example \
"Ahmad"), or null
- "item": the product in English, singular, lowercase (for example "sugar", \
"rice", "flour", "tea"), or null
- "quantity": a number (how much of the item), or null
- "unit": one of "kg", "g", "l", "ml", "pcs", "packet", "dozen", or null
- "amount": rupees as a number, or null

Rules:
- Turn number words in any language into digits (paanch sau = 500, \
dedh = 1.5, dhai = 2.5, adha = 0.5, sawa = 1.25, پانچ سو = 500).
- "500 rupees ki chini" means amount 500 and NO quantity. "2 kilo chini" means \
quantity 2, unit "kg".
- Never invent a value that was not said. Use null when you are unsure.
- Always write names and items in English letters, even if the input is in \
Urdu script.

Examples:
Input: Ahmad took 500 rupees of sugar on credit
{"commands":[{"action":"credit","customer":"Ahmad","item":"sugar","quantity":null,"unit":null,"amount":500}]}

Input: احمد نے پانچ سو روپے کی چینی ادھار لی
{"commands":[{"action":"credit","customer":"Ahmad","item":"sugar","quantity":null,"unit":null,"amount":500}]}

Input: Bilal ne 2 kilo chawal udhaar liye, 600 rupay
{"commands":[{"action":"credit","customer":"Bilal","item":"rice","quantity":2,"unit":"kg","amount":600}]}

Input: Ahmad ne 200 rupay wapas diye
{"commands":[{"action":"payment","customer":"Ahmad","item":null,"quantity":null,"unit":null,"amount":200}]}

Input: 10 kilo atta bech diya
{"commands":[{"action":"sale","customer":null,"item":"flour","quantity":10,"unit":"kg","amount":null}]}

Input: 50 packet chai stock mein add karo
{"commands":[{"action":"restock","customer":null,"item":"tea","quantity":50,"unit":"packet","amount":null}]}

Input: Ahmad took 200 rupees sugar on credit and Bilal paid back 100 rupees
{"commands":[{"action":"credit","customer":"Ahmad","item":"sugar","quantity":null,"unit":null,"amount":200},{"action":"payment","customer":"Bilal","item":null,"quantity":null,"unit":null,"amount":100}]}

Input: kal mausam acha tha
{"commands":[]}
"""

# Spoken or misspelled product names -> one canonical English name, so the app
# keeps a single stock line per product.
ITEM_ALIASES = {
    "cheeni": "sugar", "chini": "sugar", "chinni": "sugar", "چینی": "sugar",
    "chawal": "rice", "chaawal": "rice", "چاول": "rice",
    "atta": "flour", "aata": "flour", "آٹا": "flour",
    "tel": "oil", "cooking oil": "oil", "تیل": "oil",
    "ghee": "ghee", "گھی": "ghee",
    "chai": "tea", "chaye": "tea", "chai patti": "tea", "patti": "tea",
    "چائے": "tea", "پتی": "tea",
    "doodh": "milk", "dudh": "milk", "دودھ": "milk",
    "namak": "salt", "نمک": "salt",
    "daal": "lentils", "dal": "lentils", "دال": "lentils",
    "anda": "eggs", "ande": "eggs", "egg": "eggs", "انڈے": "eggs",
    "sabun": "soap", "صابن": "soap",
    "mirch": "chili", "مرچ": "chili",
    "haldi": "turmeric", "ہلدی": "turmeric",
    "pyaz": "onion", "پیاز": "onion",
    "aloo": "potato", "آلو": "potato",
    "tamatar": "tomato", "ٹماٹر": "tomato",
}

UNIT_ALIASES = {
    "kg": "kg", "kgs": "kg", "kilo": "kg", "kilos": "kg", "kilogram": "kg",
    "kilograms": "kg", "کلو": "kg",
    "g": "g", "gm": "g", "gram": "g", "grams": "g", "گرام": "g",
    "l": "l", "ltr": "l", "litre": "l", "litres": "l", "liter": "l",
    "liters": "l", "لیٹر": "l",
    "ml": "ml", "millilitre": "ml", "milliliter": "ml",
    "pcs": "pcs", "pc": "pcs", "piece": "pcs", "pieces": "pcs", "عدد": "pcs",
    "packet": "packet", "packets": "packet", "pack": "packet",
    "پیکٹ": "packet",
    "dozen": "dozen", "درجن": "dozen",
}


def _blank_to_none(value: object) -> Optional[str]:
    if value is None:
        return None
    text = " ".join(str(value).split())
    if text.lower() in {"", "null", "none", "n/a", "unknown"}:
        return None
    return text


def _to_number(value: object) -> Optional[float]:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
    else:
        try:
            number = float(str(value).replace(",", "").strip())
        except ValueError:
            return None
    return number if number > 0 else None


class Command(BaseModel):
    action: Action
    customer: Optional[str] = None
    item: Optional[str] = None
    quantity: Optional[float] = None
    unit: Optional[str] = None
    amount: Optional[float] = None

    @field_validator("customer", "item", "unit", mode="before")
    @classmethod
    def _clean_text(cls, value: object) -> Optional[str]:
        return _blank_to_none(value)

    @field_validator("quantity", "amount", mode="before")
    @classmethod
    def _clean_number(cls, value: object) -> Optional[float]:
        return _to_number(value)


def normalize(command: Command) -> Command:
    """Canonical item and unit names, grams -> kg, ml -> litres."""
    item = command.item.lower() if command.item else None
    if item:
        item = ITEM_ALIASES.get(item, item)

    unit = command.unit.lower() if command.unit else None
    quantity = command.quantity
    if unit:
        unit = UNIT_ALIASES.get(unit, unit)
    if quantity is not None and unit == "g":
        quantity, unit = quantity / 1000, "kg"
    elif quantity is not None and unit == "ml":
        quantity, unit = quantity / 1000, "l"
    if quantity is not None:
        quantity = round(quantity, 3)

    # A payment is only about money; ignore any goods the model attached.
    if command.action == "payment":
        item, quantity, unit = None, None, None

    return command.model_copy(
        update={"item": item, "quantity": quantity, "unit": unit}
    )


def parse_llm_output(raw: str) -> list[Command]:
    """Parse the model's JSON text into validated commands.

    Raises ValueError (json.JSONDecodeError is one) when the output cannot be
    used, so the caller can retry. Returns [] when the model found no action.
    """
    data = json.loads(raw)

    if isinstance(data, dict) and "commands" in data:
        items = data["commands"]
    elif isinstance(data, dict) and "action" in data:
        items = [data]  # the model returned a single bare command
    elif isinstance(data, list):
        items = data
    else:
        raise ValueError("model output has no 'commands' list")

    if not isinstance(items, list):
        raise ValueError("'commands' is not a list")

    commands: list[Command] = []
    first_error = ""
    for entry in items:
        try:
            commands.append(normalize(Command.model_validate(entry)))
        except ValidationError as exc:
            first_error = first_error or str(exc).splitlines()[0]

    if items and not commands:
        raise ValueError(f"every command was invalid ({first_error})")
    return commands
