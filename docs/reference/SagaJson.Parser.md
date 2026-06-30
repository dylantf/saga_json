---
title: SagaJson.Parser
---

Low-level JSON tokenizer and parser. Most users should go through the
`Json` opaque type and decoders instead.

## Types

### Value

```saga
type Value =
  | VNull
  | VBool Bool
  | VInt Int
  | VFloat Float
  | VString String
  | VArray (List Value)
  | VObject (List (String, Value))
  deriving (Eq, Debug)
```

A parsed JSON value mirroring the JSON grammar.

## Functions

### parse_value

```saga
fun parse_value : BitString -> Result (Value, BitString) String
```

Parse a single JSON value, returning it with the unconsumed tail.

### parse

```saga
fun parse : String -> Result Value String
```

Parse a complete JSON string.
