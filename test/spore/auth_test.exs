defmodule Spore.AuthTest do
  use ExUnit.Case, async: false

  alias Spore.Auth

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  @valid_uuid "550e8400-e29b-41d4-a716-446655440000"

  @valid_bytes <<
    0x55,
    0x0E,
    0x84,
    0x00,
    0xE2,
    0x9B,
    0x41,
    0xD4,
    0xA7,
    0x16,
    0x44,
    0x66,
    0x55,
    0x44,
    0x00,
    0x00
  >>

  describe "new/1" do
    test "key is the SHA-256 of the secret and id its lowercase hex form" do
      auth = Auth.new("hunter2")
      expected = :crypto.hash(:sha256, "hunter2")

      assert auth.key == expected
      assert byte_size(auth.key) == 32
      assert auth.id == Base.encode16(expected, case: :lower)
      assert String.length(auth.id) == 64
      assert auth.id == String.downcase(auth.id)
    end

    test "different secrets produce different keys and ids" do
      a = Auth.new("one")
      b = Auth.new("two")

      assert a.key != b.key
      assert a.id != b.id
    end
  end

  describe "new_many/1" do
    test "a binary is split on comma, space and newline, with trimming" do
      assert Auth.new_many("a, b") == [Auth.new("a"), Auth.new("b")]

      assert Auth.new_many("a,b\nc d") ==
               [Auth.new("a"), Auth.new("b"), Auth.new("c"), Auth.new("d")]

      assert Auth.new_many("solo") == [Auth.new("solo")]
      assert Auth.new_many(" , \n,") == []
    end

    test "a list is mapped through new/1" do
      assert Auth.new_many(["x", "y"]) == [Auth.new("x"), Auth.new("y")]
      assert Auth.new_many([]) == []
    end

    test "neither binary nor list yields an empty list" do
      assert Auth.new_many(nil) == []
      assert Auth.new_many(42) == []
    end
  end

  describe "answer/2 and validate/3" do
    test "answer/2 is the HMAC-SHA256 over the 16 raw UUID bytes, hex lowercase" do
      auth = Auth.new("secret")
      challenge = Auth.generate_uuid_v4()
      tag = Auth.answer(auth, challenge)

      expected =
        :crypto.mac(:hmac, :sha256, auth.key, Auth.uuid_to_bytes!(challenge))
        |> Base.encode16(case: :lower)

      assert tag == expected
      assert byte_size(tag) == 64
      assert tag == String.downcase(tag)
    end

    test "validate/3 accepts the tag produced by answer/2" do
      auth = Auth.new("secret")
      challenge = Auth.generate_uuid_v4()
      tag = Auth.answer(auth, challenge)

      assert Auth.validate(auth, challenge, tag)
      assert Auth.validate(auth, challenge, String.upcase(tag))
    end

    test "validate/3 rejects a tag computed with a different secret" do
      auth = Auth.new("secret")
      challenge = Auth.generate_uuid_v4()
      wrong = Auth.answer(Auth.new("other-secret"), challenge)

      refute Auth.validate(auth, challenge, wrong)
    end

    test "validate/3 rejects garbage hex tags without crashing" do
      auth = Auth.new("secret")
      challenge = Auth.generate_uuid_v4()

      refute Auth.validate(auth, challenge, "not-hex-at-all")
      refute Auth.validate(auth, challenge, "zz")
      refute Auth.validate(auth, challenge, "0123456789abcde")
    end

    test "validate/3 rejects an empty tag" do
      auth = Auth.new("secret")
      challenge = Auth.generate_uuid_v4()
      refute Auth.validate(auth, challenge, "")
    end

    test "validate/3 returns false for a valid tag of the wrong length" do
      auth = Auth.new("secret")
      challenge = Auth.generate_uuid_v4()
      tag = Auth.answer(auth, challenge)

      # Too short and too long: secure_compare must fail, not raise.
      refute Auth.validate(auth, challenge, String.slice(tag, 0..15))
      refute Auth.validate(auth, challenge, tag <> "00")
    end

    test "the challenge UUID case does not change the answer (HMAC over raw bytes)" do
      auth = Auth.new("secret")
      challenge = Auth.generate_uuid_v4()
      upper = String.upcase(challenge)
      mixed = mixed_case(challenge)

      assert Auth.answer(auth, upper) == Auth.answer(auth, challenge)
      assert Auth.answer(auth, mixed) == Auth.answer(auth, challenge)
      assert Auth.validate(auth, upper, Auth.answer(auth, challenge))
      assert Auth.validate(auth, mixed, Auth.answer(auth, challenge))
    end
  end

  describe "generate_uuid_v4/0" do
    test "produces canonical lowercase UUID v4 strings" do
      uuids = for _ <- 1..50, do: Auth.generate_uuid_v4()

      assert Enum.all?(uuids, &Regex.match?(@uuid_regex, &1))
      assert length(Enum.uniq(uuids)) == 50
    end
  end

  describe "uuid_to_bytes!/1" do
    test "parses a hyphenated UUID into 16 raw bytes" do
      bytes = Auth.uuid_to_bytes!(@valid_uuid)

      assert bytes == @valid_bytes
      assert byte_size(bytes) == 16
      assert is_binary(bytes)
    end

    test "accepts uppercase and mixed-case UUIDs" do
      assert Auth.uuid_to_bytes!(String.upcase(@valid_uuid)) == @valid_bytes
      assert Auth.uuid_to_bytes!(mixed_case(@valid_uuid)) == @valid_bytes
    end

    test "hyphens are optional as long as 32 hex digits remain" do
      assert Auth.uuid_to_bytes!(String.replace(@valid_uuid, "-", "")) == @valid_bytes
    end

    test "raises ArgumentError on non-hex characters" do
      assert_raise ArgumentError, ~r/invalid UUID/, fn ->
        Auth.uuid_to_bytes!("550e8400-e29b-41d4-a716-44665544000g")
      end

      assert_raise ArgumentError, ~r/invalid UUID/, fn ->
        Auth.uuid_to_bytes!("zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz")
      end
    end

    test "raises ArgumentError when the decoded length is not 16 bytes" do
      assert_raise ArgumentError, ~r/invalid UUID/, fn ->
        Auth.uuid_to_bytes!("550e8400")
      end

      assert_raise ArgumentError, ~r/invalid UUID/, fn ->
        Auth.uuid_to_bytes!(@valid_uuid <> "00")
      end

      assert_raise ArgumentError, ~r/invalid UUID/, fn ->
        Auth.uuid_to_bytes!("")
      end
    end
  end

  defp mixed_case(uuid) do
    uuid
    |> String.split("-")
    |> Enum.with_index()
    |> Enum.map(fn {part, i} ->
      if rem(i, 2) == 0, do: String.upcase(part), else: String.downcase(part)
    end)
    |> Enum.join("-")
  end
end
