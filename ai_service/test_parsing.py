"""Tests for the model-output cleaning logic. Run with: pytest"""

import json

import pytest

from parsing import Command, normalize, parse_llm_output


def raw(*commands):
    return json.dumps({"commands": list(commands)})


def test_credit_with_roman_urdu_item_becomes_english():
    result = parse_llm_output(
        raw({"action": "credit", "customer": "Ahmad", "item": "Cheeni",
             "quantity": None, "unit": None, "amount": 500})
    )
    assert len(result) == 1
    assert result[0].action == "credit"
    assert result[0].customer == "Ahmad"
    assert result[0].item == "sugar"
    assert result[0].amount == 500
    assert result[0].quantity is None


def test_urdu_script_item_alias():
    result = parse_llm_output(
        raw({"action": "sale", "item": "چاول", "quantity": 3, "unit": "کلو"})
    )
    assert result[0].item == "rice"
    assert result[0].unit == "kg"


def test_grams_convert_to_kilograms():
    result = parse_llm_output(
        raw({"action": "sale", "item": "sugar", "quantity": 500, "unit": "grams"})
    )
    assert result[0].quantity == 0.5
    assert result[0].unit == "kg"


def test_millilitres_convert_to_litres():
    result = parse_llm_output(
        raw({"action": "restock", "item": "oil", "quantity": 250, "unit": "ml"})
    )
    assert result[0].quantity == 0.25
    assert result[0].unit == "l"


def test_payment_drops_goods():
    result = parse_llm_output(
        raw({"action": "payment", "customer": "Bilal", "item": "sugar",
             "quantity": 2, "unit": "kg", "amount": 200})
    )
    assert result[0].item is None
    assert result[0].quantity is None
    assert result[0].unit is None
    assert result[0].amount == 200


def test_numbers_given_as_strings_and_junk_values():
    result = parse_llm_output(
        raw({"action": "credit", "customer": "Sara", "amount": "1,500",
             "quantity": "two", "item": "null", "unit": ""})
    )
    assert result[0].amount == 1500
    assert result[0].quantity is None  # unreadable number becomes missing
    assert result[0].item is None
    assert result[0].unit is None


def test_zero_and_negative_numbers_become_missing():
    result = parse_llm_output(
        raw({"action": "credit", "customer": "Sara", "amount": -5, "quantity": 0})
    )
    assert result[0].amount is None
    assert result[0].quantity is None


def test_two_commands_in_one_sentence():
    result = parse_llm_output(
        raw(
            {"action": "credit", "customer": "Ahmad", "amount": 200, "item": "sugar"},
            {"action": "payment", "customer": "Bilal", "amount": 100},
        )
    )
    assert [c.action for c in result] == ["credit", "payment"]


def test_no_action_returns_empty_list():
    assert parse_llm_output(raw()) == []


def test_bare_command_and_bare_list_are_accepted():
    single = json.dumps({"action": "payment", "customer": "A", "amount": 10})
    listed = json.dumps([{"action": "payment", "customer": "A", "amount": 10}])
    assert len(parse_llm_output(single)) == 1
    assert len(parse_llm_output(listed)) == 1


def test_invalid_entries_are_skipped_when_others_are_fine():
    result = parse_llm_output(
        raw({"action": "dance", "customer": "X"},
            {"action": "payment", "customer": "Ahmad", "amount": 50})
    )
    assert len(result) == 1
    assert result[0].customer == "Ahmad"


def test_all_invalid_raises_so_caller_can_retry():
    with pytest.raises(ValueError):
        parse_llm_output(raw({"action": "dance"}))


def test_garbage_raises():
    with pytest.raises(ValueError):
        parse_llm_output("sure! here you go")
    with pytest.raises(ValueError):
        parse_llm_output(json.dumps({"hello": "world"}))
    with pytest.raises(ValueError):
        parse_llm_output(json.dumps({"commands": "none"}))


def test_normalize_is_idempotent():
    cmd = Command(action="sale", item="Atta", quantity=500, unit="g")
    once = normalize(cmd)
    twice = normalize(once)
    assert once == twice
