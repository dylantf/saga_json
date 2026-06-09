---
title: SagaJson.Parser
---

JSON tokenizer and parser

Produces a `Value` ADT mirroring the JSON spec. Used internally by
SagaJson; consumers go through the `Json` opaque type and decoders.

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

A parsed JSON value. Mirrors RFC 8259's grammar.

## Functions

### parse_value

```saga
fun parse_value : BitString -> Result (Value, BitString) String
```

Parse a single JSON value, returning it with the unconsumed tail. Unlike
`parse`, this does not require the input to be fully consumed — used by
`SagaJson.Codec`'s Value bridge for tag formats that need buffering.

### parse

```saga
fun parse : String -> Result Value String
```

Parse a complete JSON document. Errors if there is trailing content.

