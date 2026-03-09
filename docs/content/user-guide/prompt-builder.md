+++
title = "Prompt Builder"
description = "Building rich prompts with the PromptBuilder DSL"
weight = 4
+++

## Overview

`ACP::PromptBuilder` provides an ergonomic DSL for constructing multi-block prompts with text, images, audio, and resource references.

## Basic Usage

Use the block form with `Session#prompt`:

```crystal
result = session.prompt do |b|
  b.text("Please review this code and suggest improvements.")
  b.resource_link("/path/to/file.cr", "text/x-crystal")
end
```

Or create a builder manually:

```crystal
builder = ACP::PromptBuilder.new
builder.text("Hello, world!")
blocks = builder.build

result = session.prompt(blocks)
```

## Content Types

### Text

```crystal
b.text("Plain text content")
```

### Image

Base64-encoded image data:

```crystal
image_data = Base64.strict_encode(File.read("screenshot.png"))
b.image(image_data, "image/png")
```

### Audio

Base64-encoded audio data:

```crystal
audio_data = Base64.strict_encode(File.read("recording.wav"))
b.audio(audio_data, "audio/wav")
```

### Embedded Resource

Include resource content directly:

```crystal
b.resource("file:///path/to/file.cr", File.read("file.cr"), "text/x-crystal")
```

### Resource Link

Reference a file by path:

```crystal
b.resource_link("/path/to/file.cr", "text/x-crystal")
```

Or with a URI and name:

```crystal
b.resource_link("file:///path/to/file.cr", "file.cr", "text/x-crystal")
```

## Builder Inspection

```crystal
builder = ACP::PromptBuilder.new
builder.text("Hello")
builder.image(data, "image/png")

builder.size    # => 2
builder.empty?  # => false
```

## Combining with Session

The `Session#prompt` method accepts multiple input forms:

```crystal
# Single text
session.prompt("Hello")

# Multiple texts
session.prompt("Context", "Question")

# Pre-built blocks
session.prompt(builder.build)

# DSL block
session.prompt { |b| b.text("Hello") }
```
