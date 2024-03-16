SET session_timezone = 'Europe/Amsterdam';

-- Type conversion functions and operators.


-- 1. SQL standard CAST operator: `CAST(value AS Type)`.

SELECT CAST(123 AS String);

-- It convert between various data types, including parameterized data types

SELECT CAST(1234567890 AS DateTime('Europe/Amsterdam'));

-- and composite data types:

SELECT CAST('[1, 2, 3]' AS Array(UInt8));

-- It's return type depends on the setting `cast_keep_nullable`. If it is enabled, if the source argument type is Nullable, the resulting data type will be also Nullable, even if it is not written explicitly:

SET cast_keep_nullable = 1;
SELECT CAST(x AS UInt8) AS y, toTypeName(y) FROM VALUES('x Nullable(String)', ('123'), ('NULL'));

SET cast_keep_nullable = 0;
SELECT CAST(x AS UInt8) AS y, toTypeName(y) FROM VALUES('x Nullable(String)', ('123'), ('NULL')); -- { serverError CANNOT_PARSE_TEXT }

-- There are various type conversion rules, some worth noting.

-- Conversion between numeric types can involve implementation defined overflow:

SELECT CAST(257 AS UInt8);
SELECT CAST(-1 AS UInt8);

-- Conversion from string acts like parsing, and for composite data types like Array, Tuple, it works in the same way as from the `Values` data format:

SELECT CAST($$['Hello', 'wo\'rld\\']$$ AS Array(String));

-- '
-- While for simple data types it does not interpret escape sequences:

SELECT arrayJoin(CAST($$['Hello', 'wo\'rld\\']$$ AS Array(String))) AS x, CAST($$wo\'rld\\$$ AS FixedString(9)) AS y;

-- The operator is case-insensitive:

SELECT CAST(123 AS String);
SELECT cast(123 AS String);
SELECT Cast(123 AS String);

-- Conversion from a floating point value to an integer will involve truncation towards zero:

SELECT CAST(1.9, 'Int64'), CAST(-1.9, 'Int64');

-- Conversion from NULL into a non-Nullable type will throw an exception, as well as conversions from denormal floating point numbers (NaN, inf, -inf) to an integer, or conversion between arrays of different dimensions.

-- However, you might find it amusing that an empty array of Nothing data type can be converted to arrays of any dimensions:

SELECT [] AS x, CAST(x AS Array(Array(Array(Tuple(UInt64, String))))) AS y, toTypeName(x), toTypeName(y);


-- 2. The functional form of this operator: `CAST(value, 'Type')`:

SELECT CAST(123, 'String');

-- This form is equivalent. Keep in mind that the type has to be a constant expression:

SELECT CAST(123, 'Str'||'ing'); -- this works.

-- This does not work: SELECT materialize('String') AS type, CAST(123, type);

-- It is also case-insensitive:

SELECT CasT(123, 'String');

-- The functional form exists for the consistency of implementation (as every operator also exists in the functional form and the functional form is represented in the query's Abstract Syntax Tree). Anyway, the functional form also makes sense for users, when they need to construct a data type name from a constant expression, or when they want to generate a query programmatically.

-- It's worth noting that the operator form does not allow to specify the type name as a string literal:

-- This does not work: SELECT CAST(123 AS 'String');

-- By only allowing it as an identifier, either bare word:

SELECT CAST(123 AS String);

-- Or as a MySQL or PostgreSQL quoted identifiers:

SELECT CAST(123 AS `String`);
SELECT CAST(123 AS "String");

-- While the functional form only allows the type name as a string literal:

SELECT CAST(123, 'String'); -- works
SELECT CAST(123, String); -- { serverError UNKNOWN_IDENTIFIER }

-- However, you can cheat:

SELECT 'String' AS String, CAST(123, String);


-- 3. The internal function `_CAST` which is different from `CAST` only by being not dependent on the value of `cast_keep_nullable` setting and other settings.

-- This is needed when ClickHouse has to persist an expression for future use, like in table definitions, including primary and partition key and other indices.

-- The function is not intended for being used directly. When a user uses a regular `CAST` operator or function in a table definition, it is transparently converted to `_CAST` to persist its behavior. However, the user can still use the internal version directly:

SELECT _CAST(x, 'UInt8') AS y, toTypeName(y) FROM VALUES('x Nullable(String)', ('123'), ('456'));

-- There is no operator form of this function:

--  does not work, here UInt8 is interpreted as an alias for the value:
SELECT _CAST(123 AS UInt8); -- { serverError NUMBER_OF_ARGUMENTS_DOESNT_MATCH }

SELECT CAST(123 AS UInt8); -- works


-- 4. PostgreSQL-style cast syntax `::`

SELECT 123::String;

-- It has a difference from the `CAST` operator: if it is applied to a simple literal value, instead of performing a type conversion, it invokes the SQL parser directly on the corresponding text fragment of the query. The most important case will be the floating-point and decimal types.

-- In this example, we parse `1.1` as Decimal and not involving any type conversion:

SELECT 1.1::Decimal(30, 20);

-- In this example, `1.1` is first parsed as usual, yielding a Float64 value, and then converted to Decimal, producing a wrong result:

SELECT CAST(1.1 AS Decimal(30, 20));

-- We can change this behavior in the future.

-- Another example:

SELECT -1::UInt64; -- { serverError CANNOT_PARSE_NUMBER }

SELECT CAST(-1 AS UInt64); -- conversion with overflow

-- For composite data types, if a value is a literal, it is parsed directly:

SELECT [1.1, 2.3]::Array(Decimal(30, 20));

-- But if the value contains expressions, the usage of the `::` operator will be equivalent to invoking the CAST operator on the expression:

SELECT [1.1, 2.3 + 0]::Array(Decimal(30, 20));

-- The automatic column name for the result of an application of the `::` operator may be the same as for the result of an application of the CAST operator to a string containing the corresponding fragment of the query or to a corresponding expression:

SELECT 1.1::Decimal(30, 20), CAST('1.1' AS Decimal(30, 20)), (1+1)::UInt8 FORMAT Vertical;

-- The operator has the highest priority among others:

SELECT 1-1::String; -- { serverError ILLEGAL_TYPE_OF_ARGUMENT }

-- But one interesting example is the unary minus. Here the minus is not an operator, but part of the numeric literal:

SELECT -1::String;

-- Here it is an operator:

SELECT 1 AS x, -x::String; -- { serverError ILLEGAL_TYPE_OF_ARGUMENT }


-- 5. Accurate casting functions: `accurateCast`, `accurateCastOrNull`, `accurateCastOrDefault`.

-- These functions check if the value is exactly representable in the target data type.

-- The function `accurateCast` performs the conversion or throws an exception if the value is not exactly representable:

SELECT accurateCast(1.123456789, 'Float32'); -- { serverError CANNOT_CONVERT_TYPE }

-- The function `accurateCastOrNull` always wraps the target type into Nullable, and returns NULL if the value is not exactly representable:

SELECT accurateCastOrNull(1.123456789, 'Float32');

-- The function `accurateCastOrDefault` takes an additional parameter, which must be of the target type, and returns it if the value is not exactly representable:

SELECT accurateCastOrDefault(-1, 'UInt64', 0::UInt64);

-- These functions are case-sensitive and there are no corresponding operators:

SELECT ACCURATECAST(1, 'String'); -- { serverError UNKNOWN_FUNCTION }.


-- 6. Explicit conversion functions:

-- `toString`, `toFixedString`,
-- `toUInt8`, `toUInt16`, `toUInt32`, `toUInt64`, `toUInt128`, `toUInt256`,
-- `toInt8`, `toInt16`, `toInt32`, `toInt64`, `toInt128`, `toInt256`,
-- `toFloat32`, `toFloat64`,
-- `toDecimal32`, `toDecimal64`, `toDecimal128`, `toDecimal256`,
-- `toDate`, `toDate32`, `toDateTime`, `toDateTime64`,
-- `toUUID`, `toIPv4`, `toIPv6`,
-- `toIntervalNanosecond`, `toIntervalMicrosecond`, `toIntervalMillisecond`,
-- `toIntervalSecond`, `toIntervalMinute`, `toIntervalHour`,
-- `toIntervalDay`, `toIntervalWeek`, `toIntervalMonth`, `toIntervalQuarter`, `toIntervalYear`

-- These functions work under the same rules as the CAST operator, and can be thought as a elementary implementation parts of that operator. They allow implementation defined overflow while converting between numeric types.

SELECT toUInt8(-1);

-- These are ClickHouse-native conversion functions. They take an argument with the input value, and for some of data types (`FixedString`, `DateTime`, `DateTime64`, `Decimal`s) the subsequent arguments are constant expressions, defining the parameters of these data types, or the rules to interpret the source value.

SELECT toFloat64(123); -- no arguments
SELECT toFixedString('Hello', 10) FORMAT TSV; -- the parameter of the FixedString data type, the function returns FixedString(10)
SELECT toFixedString('Hello', 5 + 5) FORMAT TSV; -- it can be a constant expression

SELECT toDecimal32('123.456', 2); -- the scale of the Decimal data type

SELECT toDateTime('2024-04-25 01:02:03', 'Europe/Amsterdam'); -- the time zone of DateTime
SELECT toDateTime64('2024-04-25 01:02:03', 6, 'Europe/Amsterdam'); -- the scale of DateTime64 and its time zone

-- The length of FixedString and the scale of Decimal and DateTime64 types are mandatory arguments, while the time zone of the DateTime data type is optional.

-- If the time zone is not specified, the time zone of the argument's data type is used, and if the argument is not a date time, the session time zone is used.

SELECT toDateTime('2024-04-25 01:02:03');
SELECT toDateTime64('2024-04-25 01:02:03.456789', 6);

-- Here the time zone can be specified as the rule of interpretation of the value during conversion:

SELECT toString(1710612085::DateTime, 'America/Los_Angeles');
SELECT toString(1710612085::DateTime);


-- 7. SQL-compatibility type-defining operators:

SELECT DATE '2024-04-25', TIMESTAMP '2024-01-01 02:03:04', INTERVAL 1 MINUTE, INTERVAL '12 hour';

-- These operators are interpreted as the corresponding explicit conversion functions.


-- 8. SQL-compatibility aliases for explicit conversion functions:

SELECT DATE('2024-04-25'), TIMESTAMP('2024-01-01 02:03:04'), FROM_UNIXTIME(1234567890);

-- These functions exist for compatibility with MySQL. They are case-insensive.

SELECT date '2024-04-25', timeSTAMP('2024-01-01 02:03:04'), From_Unixtime(1234567890);


-- 9. Specialized conversion functions:

-- `parseDateTimeBestEffort`, `parseDateTimeBestEffortUS`, `parseDateTime64BestEffort`, `parseDateTime64BestEffortUS`, `toUnixTimestamp`

-- These functions are similar to explicit conversion functions, but provide special rules on how the conversion is performed.

SELECT parseDateTimeBestEffort('25 Apr 1986 1pm');


-- 10. Functions for converting between different components or rounding of date and time data types.

SELECT toDayOfMonth(toDateTime(1234567890));

-- These functions are coverted in a separate topic.
