# IDL 4.2 Consolidated Grammar — Annex A

Source: OMG IDL 4.2 (formal/18-01-05), Annex A (spec pages 123–132).
All 227 grammar rules, organized by Building Block.

## Notation

- `::=` — production rule (first definition)
- `::+` — rule extension (adds alternatives to an existing rule)
- `[ … ]` — optional element
- `{ … }*` — zero or more repetitions
- `{ … }+` — one or more repetitions (written as `X+` in the spec)
- `|` — alternative
- Quoted strings are literal terminals.

---

## Building Block Core Data Types (Rules 1–68)

```
(1)   specification           ::= definition+

(2)   definition              ::= module_dcl ";"
                                | const_dcl ";"
                                | type_dcl ";"

(3)   module_dcl              ::= "module" identifier "{" definition+ "}"

(4)   scoped_name             ::= identifier
                                | "::" identifier
                                | scoped_name "::" identifier

(5)   const_dcl               ::= "const" const_type identifier "=" const_expr

(6)   const_type              ::= integer_type
                                | floating_pt_type
                                | fixed_pt_const_type
                                | char_type
                                | wide_char_type
                                | boolean_type
                                | octet_type
                                | string_type
                                | wide_string_type
                                | scoped_name

(7)   const_expr              ::= or_expr

(8)   or_expr                 ::= xor_expr
                                | or_expr "|" xor_expr

(9)   xor_expr                ::= and_expr
                                | xor_expr "^" and_expr

(10)  and_expr                ::= shift_expr
                                | and_expr "&" shift_expr

(11)  shift_expr              ::= add_expr
                                | shift_expr ">>" add_expr
                                | shift_expr "<<" add_expr

(12)  add_expr                ::= mult_expr
                                | add_expr "+" mult_expr
                                | add_expr "-" mult_expr

(13)  mult_expr               ::= unary_expr
                                | mult_expr "*" unary_expr
                                | mult_expr "/" unary_expr
                                | mult_expr "%" unary_expr

(14)  unary_expr              ::= unary_operator primary_expr
                                | primary_expr

(15)  unary_operator          ::= "-" | "+" | "~"

(16)  primary_expr            ::= scoped_name
                                | literal
                                | "(" const_expr ")"

(17)  literal                 ::= integer_literal
                                | floating_pt_literal
                                | fixed_pt_literal
                                | character_literal
                                | wide_character_literal
                                | boolean_literal
                                | string_literal
                                | wide_string_literal

(18)  boolean_literal         ::= "TRUE" | "FALSE"

(19)  positive_int_const      ::= const_expr

(20)  type_dcl                ::= constr_type_dcl | native_dcl | typedef_dcl

(21)  type_spec               ::= simple_type_spec

(22)  simple_type_spec        ::= base_type_spec | scoped_name

(23)  base_type_spec          ::= integer_type
                                | floating_pt_type
                                | char_type
                                | wide_char_type
                                | boolean_type
                                | octet_type

(24)  floating_pt_type        ::= "float" | "double" | "long" "double"

(25)  integer_type            ::= signed_int | unsigned_int

(26)  signed_int              ::= signed_short_int
                                | signed_long_int
                                | signed_longlong_int

(27)  signed_short_int        ::= "short"

(28)  signed_long_int         ::= "long"

(29)  signed_longlong_int     ::= "long" "long"

(30)  unsigned_int            ::= unsigned_short_int
                                | unsigned_long_int
                                | unsigned_longlong_int

(31)  unsigned_short_int      ::= "unsigned" "short"

(32)  unsigned_long_int       ::= "unsigned" "long"

(33)  unsigned_longlong_int   ::= "unsigned" "long" "long"

(34)  char_type               ::= "char"

(35)  wide_char_type          ::= "wchar"

(36)  boolean_type            ::= "boolean"

(37)  octet_type              ::= "octet"

(38)  template_type_spec      ::= sequence_type
                                | string_type
                                | wide_string_type
                                | fixed_pt_type

(39)  sequence_type           ::= "sequence" "<" type_spec "," positive_int_const ">"
                                | "sequence" "<" type_spec ">"

(40)  string_type             ::= "string" "<" positive_int_const ">"
                                | "string"

(41)  wide_string_type        ::= "wstring" "<" positive_int_const ">"
                                | "wstring"

(42)  fixed_pt_type           ::= "fixed" "<" positive_int_const "," positive_int_const ">"

(43)  fixed_pt_const_type     ::= "fixed"

(44)  constr_type_dcl         ::= struct_dcl | union_dcl | enum_dcl

(45)  struct_dcl              ::= struct_def | struct_forward_dcl

(46)  struct_def              ::= "struct" identifier "{" member+ "}"

(47)  member                  ::= type_spec declarators ";"

(48)  struct_forward_dcl      ::= "struct" identifier

(49)  union_dcl               ::= union_def | union_forward_dcl

(50)  union_def               ::= "union" identifier "switch" "(" switch_type_spec ")"
                                  "{" switch_body "}"

(51)  switch_type_spec        ::= integer_type | char_type | boolean_type | scoped_name

(52)  switch_body             ::= case+

(53)  case                    ::= case_label+ element_spec ";"

(54)  case_label              ::= "case" const_expr ":" | "default" ":"

(55)  element_spec            ::= type_spec declarator

(56)  union_forward_dcl       ::= "union" identifier

(57)  enum_dcl                ::= "enum" identifier "{" enumerator { "," enumerator }* "}"

(58)  enumerator              ::= identifier

(59)  array_declarator        ::= identifier fixed_array_size+

(60)  fixed_array_size        ::= "[" positive_int_const "]"

(61)  native_dcl              ::= "native" simple_declarator

(62)  simple_declarator       ::= identifier

(63)  typedef_dcl             ::= "typedef" type_declarator

(64)  type_declarator         ::= { simple_type_spec | template_type_spec | constr_type_dcl }
                                  any_declarators

(65)  any_declarators         ::= any_declarator { "," any_declarator }*

(66)  any_declarator          ::= simple_declarator | array_declarator

(67)  declarators             ::= declarator { "," declarator }*

(68)  declarator              ::= simple_declarator
```

---

## Building Block Any (Rules 69–70)

```
(69)  base_type_spec          ::+ any_type

(70)  any_type                ::= "any"
```

---

## Building Block Interfaces – Basic (Rules 71–96)

```
(71)  definition              ::+ except_dcl ";"
                                | interface_dcl ";"

(72)  except_dcl              ::= "exception" identifier "{" member* "}"

(73)  interface_dcl           ::= interface_def | interface_forward_dcl

(74)  interface_def           ::= interface_header "{" interface_body "}"

(75)  interface_forward_dcl   ::= interface_kind identifier

(76)  interface_header        ::= interface_kind identifier [ interface_inheritance_spec ]

(77)  interface_kind          ::= "interface"

(78)  interface_inheritance_spec
                              ::= ":" interface_name { "," interface_name }*

(79)  interface_name          ::= scoped_name

(80)  interface_body          ::= export*

(81)  export                  ::= op_dcl ";" | attr_dcl ";"

(82)  op_dcl                  ::= op_type_spec identifier "(" [ parameter_dcls ] ")"
                                  [ raises_expr ]

(83)  op_type_spec            ::= type_spec | "void"

(84)  parameter_dcls          ::= param_dcl { "," param_dcl }*

(85)  param_dcl               ::= param_attribute type_spec simple_declarator

(86)  param_attribute         ::= "in" | "out" | "inout"

(87)  raises_expr             ::= "raises" "(" scoped_name { "," scoped_name }* ")"

(88)  attr_dcl                ::= readonly_attr_spec | attr_spec

(89)  readonly_attr_spec      ::= "readonly" "attribute" type_spec readonly_attr_declarator

(90)  readonly_attr_declarator
                              ::= simple_declarator raises_expr
                                | simple_declarator { "," simple_declarator }*

(91)  attr_spec               ::= "attribute" type_spec attr_declarator

(92)  attr_declarator         ::= simple_declarator attr_raises_expr
                                | simple_declarator { "," simple_declarator }*

(93)  attr_raises_expr        ::= get_excep_expr [ set_excep_expr ]
                                | set_excep_expr

(94)  get_excep_expr          ::= "getraises" exception_list

(95)  set_excep_expr          ::= "setraises" exception_list

(96)  exception_list          ::= "(" scoped_name { "," scoped_name }* ")"
```

---

## Building Block Interfaces – Full (Rule 97)

```
(97)  export                  ::+ type_dcl ";"
                                | const_dcl ";"
                                | except_dcl ";"
```

---

## Building Block Value Types (Rules 98–110)

```
(98)  definition              ::+ value_dcl ";"

(99)  value_dcl               ::= value_def | value_forward_dcl

(100) value_def               ::= value_header "{" value_element* "}"

(101) value_header            ::= value_kind identifier [ value_inheritance_spec ]

(102) value_kind              ::= "valuetype"

(103) value_inheritance_spec  ::= [ ":" [ "truncatable" ] value_name { "," value_name }*
                                   [ "supports" interface_name ]* ]

(104) value_name              ::= scoped_name

(105) value_element           ::= export | state_member | init_dcl

(106) state_member            ::= ( "public" | "private" ) type_spec declarators ";"

(107) init_dcl                ::= "factory" identifier "(" [ init_param_dcls ] ")"
                                  [ raises_expr ] ";"

(108) init_param_dcls         ::= init_param_dcl { "," init_param_dcl }*

(109) init_param_dcl          ::= "in" type_spec simple_declarator

(110) value_forward_dcl       ::= value_kind identifier
```

---

## Building Block CORBA-Specific – Interfaces (Rules 111–124)

```
(111) definition              ::+ type_id_dcl ";"
                                | type_prefix_dcl ";"
                                | import_dcl ";"

(112) export                  ::+ type_id_dcl ";"
                                | type_prefix_dcl ";"
                                | import_dcl ";"
                                | op_oneway_dcl

(113) type_id_dcl             ::= "typeid" scoped_name string_literal

(114) type_prefix_dcl         ::= "typeprefix" scoped_name string_literal

(115) import_dcl              ::= "import" imported_scope

(116) imported_scope          ::= scoped_name | string_literal

(117) base_type_spec          ::+ object_type

(118) object_type             ::= "Object"

(119) interface_kind          ::+ "local" "interface"

(120) op_oneway_dcl           ::= "oneway" "void" identifier "(" [ in_parameter_dcls ] ")"

(121) in_parameter_dcls       ::= in_param_dcl { "," in_param_dcl }*

(122) in_param_dcl            ::= "in" type_spec simple_declarator

(123) op_with_context         ::= { op_dcl | op_oneway_dcl } context_expr

(124) context_expr            ::= "context" "(" string_literal { "," string_literal }* ")"
```

---

## Building Block CORBA-Specific – Value Types (Rules 125–132)

```
(125) value_dcl               ::+ value_box_def | value_abs_def

(126) value_box_def           ::= "valuetype" identifier type_spec

(127) value_abs_def           ::= "abstract" "valuetype" identifier
                                  [ value_inheritance_spec ] "{" export* "}"

(128) value_kind              ::+ "custom" "valuetype"

(129) interface_kind          ::+ "abstract" "interface"

(130) value_inheritance_spec  ::+ ":" [ "truncatable" ] value_name { "," value_name }*
                                  [ "supports" interface_name ]* ]

(131) base_type_spec          ::+ value_base_type

(132) value_base_type         ::= "ValueBase"
```

---

## Building Block Components – Basic (Rules 133–143)

```
(133) definition              ::+ component_dcl ";"

(134) component_dcl           ::= component_def | component_forward_dcl

(135) component_forward_dcl   ::= "component" identifier

(136) component_def           ::= component_header "{" component_body "}"

(137) component_header        ::= "component" identifier [ component_inheritance_spec ]

(138) component_inheritance_spec
                              ::= ":" scoped_name

(139) component_body          ::= component_export*

(140) component_export        ::= provides_dcl ";"
                                | uses_dcl ";"
                                | attr_dcl ";"

(141) provides_dcl            ::= "provides" interface_type identifier

(142) interface_type          ::= scoped_name

(143) uses_dcl                ::= "uses" interface_type identifier
```

---

## Building Block Components – Homes (Rules 144–152)

```
(144) definition              ::+ home_dcl ";"

(145) home_dcl                ::= home_header "{" home_body "}"

(146) home_header             ::= "home" identifier [ home_inheritance_spec ]
                                  "manages" scoped_name

(147) home_inheritance_spec   ::= ":" scoped_name

(148) home_body               ::= home_export*

(149) home_export             ::= export | factory_dcl ";"

(150) factory_dcl             ::= "factory" identifier "(" [ factory_param_dcls ] ")"
                                  [ raises_expr ]

(151) factory_param_dcls      ::= factory_param_dcl { "," factory_param_dcl }*

(152) factory_param_dcl       ::= "in" type_spec simple_declarator
```

---

## Building Block CCM-Specific (Rules 153–170)

```
(153) definition              ::+ event_dcl ";"

(154) component_header        ::+ "component" identifier [ component_inheritance_spec ]
                                  supported_interface_spec

(155) supported_interface_spec
                              ::= "supports" scoped_name { "," scoped_name }*

(156) component_export        ::+ emits_dcl ";"
                                | publishes_dcl ";"
                                | consumes_dcl ";"

(157) interface_type          ::+ "Object"

(158) uses_dcl                ::+ "uses" "multiple" interface_type identifier

(159) emits_dcl               ::= "emits" scoped_name identifier

(160) publishes_dcl           ::= "publishes" scoped_name identifier

(161) consumes_dcl            ::= "consumes" scoped_name identifier

(162) home_header             ::+ "home" identifier [ home_inheritance_spec ]
                                  [ supported_interface_spec ]
                                  "manages" scoped_name [ primary_key_spec ]

(163) primary_key_spec        ::= "primarykey" scoped_name

(164) home_export             ::+ finder_dcl ";"

(165) finder_dcl              ::= "finder" identifier "(" [ init_param_dcls ] ")"
                                  [ raises_expr ]

(166) event_dcl               ::= ( event_def | event_abs_def | event_forward_dcl )

(167) event_forward_dcl       ::= [ "abstract" ] "eventtype" identifier

(168) event_abs_def           ::= "abstract" "eventtype" identifier
                                  [ value_inheritance_spec ] "{" export* "}"

(169) event_def               ::= event_header "{" value_element* "}"

(170) event_header            ::= [ "custom" ] "eventtype" identifier
                                  [ value_inheritance_spec ]
```

---

## Building Block Components – Ports and Connectors (Rules 171–183)

```
(171) definition              ::+ porttype_dcl ";"
                                | connector_dcl ";"

(172) porttype_dcl            ::= porttype_def | porttype_forward_dcl

(173) porttype_forward_dcl    ::= "porttype" identifier

(174) porttype_def            ::= "porttype" identifier "{" port_body "}"

(175) port_body               ::= port_ref port_export*

(176) port_ref                ::= provides_dcl ";"
                                | uses_dcl ";"
                                | port_dcl ";"

(177) port_export             ::= port_ref | attr_dcl ";"

(178) port_dcl                ::= { "port" | "mirrorport" } scoped_name identifier

(179) component_export        ::+ port_dcl ";"

(180) connector_dcl           ::= connector_header "{" connector_export+ "}"

(181) connector_header        ::= "connector" identifier [ connector_inherit_spec ]

(182) connector_inherit_spec  ::= ":" scoped_name

(183) connector_export        ::= port_ref | attr_dcl ";"
```

---

## Building Block Template Modules (Rules 184–194)

```
(184) definition              ::+ template_module_dcl ";"
                                | template_module_inst ";"

(185) template_module_dcl     ::= "module" identifier "<" formal_parameters ">"
                                  "{" tpl_definition+ "}"

(186) formal_parameters       ::= formal_parameter { "," formal_parameter }*

(187) formal_parameter        ::= formal_parameter_type identifier

(188) formal_parameter_type   ::= "typename" | "interface" | "valuetype" | "eventtype"
                                | "struct" | "union" | "exception" | "enum" | "sequence"
                                | "const" const_type
                                | sequence_type

(189) tpl_definition          ::= definition | template_module_ref ";"

(190) template_module_inst    ::= "module" scoped_name "<" actual_parameters ">" identifier

(191) actual_parameters       ::= actual_parameter { "," actual_parameter }*

(192) actual_parameter        ::= type_spec | const_expr

(193) template_module_ref     ::= "alias" scoped_name "<" formal_parameter_names ">"
                                  identifier

(194) formal_parameter_names  ::= identifier { "," identifier }*
```

---

## Building Block Extended Data Types (Rules 195–215)

```
(195) struct_def              ::+ "struct" identifier ":" scoped_name "{" member* "}"
                                | "struct" identifier "{" "}"

(196) switch_type_spec        ::+ wide_char_type | octet_type

(197) template_type_spec      ::+ map_type

(198) constr_type_dcl         ::+ bitset_dcl | bitmask_dcl

(199) map_type                ::= "map" "<" type_spec "," type_spec ","
                                  positive_int_const ">"
                                | "map" "<" type_spec "," type_spec ">"

(200) bitset_dcl              ::= "bitset" identifier [ ":" scoped_name ]
                                  "{" bitfield* "}"

(201) bitfield                ::= bitfield_spec identifier* ";"

(202) bitfield_spec           ::= "bitfield" "<" positive_int_const ">"
                                | "bitfield" "<" positive_int_const ","
                                  destination_type ">"

(203) destination_type        ::= boolean_type | octet_type | integer_type

(204) bitmask_dcl             ::= "bitmask" identifier "{" bit_value { "," bit_value }* "}"

(205) bit_value               ::= identifier

(206) signed_int              ::+ signed_tiny_int

(207) unsigned_int            ::+ unsigned_tiny_int

(208) signed_tiny_int         ::= "int8"

(209) unsigned_tiny_int       ::= "uint8"

(210) signed_short_int        ::+ "int16"

(211) signed_long_int         ::+ "int32"

(212) signed_longlong_int     ::+ "int64"

(213) unsigned_short_int      ::+ "uint16"

(214) unsigned_long_int       ::+ "uint32"

(215) unsigned_longlong_int   ::+ "uint64"
```

---

## Building Block Anonymous Types (Rules 216–217)

```
(216) type_spec               ::+ template_type_spec

(217) declarator              ::+ array_declarator
```

---

## Building Block Annotations (Rules 218–227)

```
(218) definition              ::+ annotation_dcl ";"

(219) annotation_dcl          ::= annotation_header "{" annotation_body "}"

(220) annotation_header       ::= "@annotation" identifier

(221) annotation_body         ::= { annotation_member
                                  | enum_dcl ";"
                                  | const_dcl ";"
                                  | typedef_dcl ";"
                                  }*

(222) annotation_member       ::= annotation_member_type simple_declarator
                                  [ "default" const_expr ] ";"

(223) annotation_member_type  ::= const_type | any_const_type | scoped_name

(224) any_const_type          ::= "any"

(225) annotation_appl         ::= "@" scoped_name [ "(" annotation_appl_params ")" ]

(226) annotation_appl_params  ::= const_expr
                                | annotation_appl_param { "," annotation_appl_param }*

(227) annotation_appl_param   ::= identifier "=" const_expr
```

---

## Rule Count by Building Block

| Building Block | Rules | Range |
|---|---|---|
| Core Data Types | 68 | 1–68 |
| Any | 2 | 69–70 |
| Interfaces – Basic | 26 | 71–96 |
| Interfaces – Full | 1 | 97 |
| Value Types | 13 | 98–110 |
| CORBA-Specific – Interfaces | 14 | 111–124 |
| CORBA-Specific – Value Types | 8 | 125–132 |
| Components – Basic | 11 | 133–143 |
| Components – Homes | 9 | 144–152 |
| CCM-Specific | 18 | 153–170 |
| Components – Ports and Connectors | 13 | 171–183 |
| Template Modules | 11 | 184–194 |
| Extended Data Types | 21 | 195–215 |
| Anonymous Types | 2 | 216–217 |
| Annotations | 10 | 218–227 |
| **Total** | **227** | |

## zidl Parser Coverage Notes

- Rules 1–68 (Core), 69–70 (Any), 71–96 (Interfaces Basic), 97 (Interfaces Full),
  98–110 (Value Types), 111–124 (CORBA-Specific Interfaces), 125–132 (CORBA-Specific
  Value Types), 133–143 (Components Basic), 144–152 (Homes), 153–170 (CCM), 171–183
  (Ports/Connectors), 184–194 (Template Modules), 195–215 (Extended Data Types),
  216–217 (Anonymous Types), 218–227 (Annotations): **All 227 rules implemented in parser**.
- IR builder: silently drops valuetypes, components, homes, CCM, ports/connectors, template
  modules; emits a warning diagnostic per dropped construct. The parser itself fully parses them.
- Backends generate code for: structs, unions, enums, typedefs, bitmasks, bitsets, interfaces,
  modules, and the Extended Data Types integer aliases (int8, uint8, etc.).
