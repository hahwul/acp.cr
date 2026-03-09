+++
title = "PromptBuilder"
description = "DSL for constructing multi-block prompts"
weight = 5
+++

## Overview

`ACP::PromptBuilder` provides a builder pattern for constructing arrays of `ContentBlock` objects. It supports text, images, audio, embedded resources, and resource links.

## Constructor

```crystal
ACP::PromptBuilder.new
```

Creates a new empty builder.

## Methods

### `#text`

```crystal
builder.text(content : String) : ACP::PromptBuilder
```

Adds a text content block. Returns `self` for chaining.

### `#image`

```crystal
builder.image(
  data : String,
  mime_type : String? = nil
) : ACP::PromptBuilder
```

Adds a base64-encoded image content block.

### `#audio`

```crystal
builder.audio(
  data : String,
  mime_type : String? = nil
) : ACP::PromptBuilder
```

Adds a base64-encoded audio content block.

### `#resource`

```crystal
builder.resource(
  uri : String,
  text : String,
  mime_type : String? = nil
) : ACP::PromptBuilder
```

Adds an embedded resource content block with inline text content.

### `#resource_link(path)`

```crystal
builder.resource_link(
  path : String,
  mime_type : String? = nil
) : ACP::PromptBuilder
```

Adds a resource link from a file path. Automatically converts to a `file://` URI.

### `#resource_link(uri, name)`

```crystal
builder.resource_link(
  uri : String,
  name : String,
  mime_type : String? = nil
) : ACP::PromptBuilder
```

Adds a resource link with an explicit URI and display name.

### `#build`

```crystal
builder.build : Array(ACP::Protocol::ContentBlock)
```

Returns the assembled array of content blocks.

### `#size`

```crystal
builder.size : Int32
```

Returns the number of content blocks.

### `#empty?`

```crystal
builder.empty? : Bool
```

Returns `true` if no content blocks have been added.

## Example

```crystal
builder = ACP::PromptBuilder.new
builder
  .text("Review the following files for security issues:")
  .resource_link("/src/auth.cr", "text/x-crystal")
  .resource_link("/src/api.cr", "text/x-crystal")
  .text("Focus on input validation and SQL injection risks.")

blocks = builder.build
result = session.prompt(blocks)
```
