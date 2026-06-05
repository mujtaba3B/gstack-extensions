"""Unit tests for the qa:browser recipe validator.

Run a single file (machine-resource rule: never the whole suite):
    python3 -m pytest qa/skills/browser/scripts/test_validate_recipe.py -q
"""
import importlib.util
import pathlib

_SPEC = importlib.util.spec_from_file_location(
    "validate_recipe", pathlib.Path(__file__).with_name("validate-recipe.py")
)
validate_recipe = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(validate_recipe)
validate_recipe_text = validate_recipe.validate_recipe_text

VALID = """\
version: 1
app_root: user_growth
base_url: http://localhost:8000
boot: ./dev-setup.sh {email}
tag_prefix: people/qa-verify-
seed_command: python manage.py qa_seed --tag {tag_prefix}
teardown_command: python manage.py qa_teardown --tag {tag_prefix}
"""


def test_valid_recipe_passes():
    assert validate_recipe_text(VALID) == []


def test_op_reference_is_allowed():
    text = VALID + "token: op://AI CLI/some item/password\n"
    assert validate_recipe_text(text) == []


def test_inline_secret_fails():
    text = VALID + "token: sk-ABCD1234EFGH5678\n"
    problems = validate_recipe_text(text)
    assert any("inline secret" in p for p in problems)


def test_slack_token_fails():
    text = VALID + "hook: xoxb-123456789012-abcdef\n"
    assert any("inline secret" in p for p in validate_recipe_text(text))


def test_absolute_path_fails():
    text = VALID + "boot_dir: /Users/mujtaba/dev/app\n"
    assert any("absolute machine path" in p for p in validate_recipe_text(text))


def test_unscoped_teardown_fails():
    text = VALID.replace(
        "teardown_command: python manage.py qa_teardown --tag {tag_prefix}",
        "teardown_command: python manage.py flush --no-input",
    )
    assert any("not scoped to tag_prefix" in p for p in validate_recipe_text(text))


def test_missing_required_key_fails():
    text = "app_root: .\nboot: ./serve.sh\n"  # no base_url
    assert any("missing required key: base_url" in p for p in validate_recipe_text(text))


def test_comments_do_not_false_trigger():
    text = VALID + "# example: do not put a sk-REALKEYHERE in here\n"
    # commented line is skipped, so no secret problem from the comment
    assert validate_recipe_text(text) == []
