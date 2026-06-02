# Messages Actions Reference

Actions for finding, filtering, and working with iMessage/SMS messages in Shortcuts.

## Overview

There are **two generations** of Messages actions:

| Action | ID | Type | Status |
|--------|-----|------|--------|
| Find Message | `com.apple.MobileSMS.MessageEntity` | appIntent | ✅ Current |
| Find Conversation | `com.apple.MobileSMS.ConversationEntity` | appIntent | ✅ Current |
| Search For Messages | `com.apple.MobileSMS.INSearchForMessagesIntent` | siriIntent | ⚠️ Deprecated |
| Send Message | `com.apple.MobileSMS.INSendMessageIntent` | siriIntent | ⚠️ Deprecated |
| Send Reply | `com.apple.MobileSMS.SendReplyIntent` | appIntent | ✅ Current |
| Delete Message | `com.apple.MobileSMS.DeleteMessageIntent` | appIntent | ✅ Current |
| Delete Conversation | `com.apple.MobileSMS.DeleteConversationIntent` | appIntent | ✅ Current |
| Reveal Message | `com.apple.MobileSMS.OpenMessageIntent` | appIntent | ✅ Current |
| Open Conversation | `com.apple.MobileSMS.OpenConversationIntent` | appIntent | ✅ Current |
| Open Inbox | `com.apple.MobileSMS.ChangeFilterModeIntent` | appIntent | ✅ Current |
| Mark as Read | `com.apple.MobileSMS.MarkConversationAsUnreadIntent` | appIntent | ✅ Current |
| Mute Conversation | `com.apple.MobileSMS.MuteConversationIntent` | appIntent | ✅ Current |
| Send Tapback | `com.apple.MobileSMS.SendTapbackIntent` | appIntent | ✅ Current |
| Remove Tapback | `com.apple.MobileSMS.RemoveTapbackIntent` | appIntent | ✅ Current |
| Send Reaction | `com.apple.MobileSMS.SendMessageReactionIntent` | appIntent | ✅ Current |

---

## Find Message (com.apple.MobileSMS.MessageEntity)

The **current** way to find/filter messages. Uses the same `WFContentItemFilter` system as Find Photos.

### Invocation

AppIntents use `is.workflow.actions.appintentexecution`:

```xml
<dict>
    <key>WFWorkflowActionIdentifier</key>
    <string>is.workflow.actions.appintentexecution</string>
    <key>WFWorkflowActionParameters</key>
    <dict>
        <key>UUID</key>
        <string>FIND-MSG-UUID</string>
        <key>AppIntentDescriptor</key>
        <dict>
            <key>BundleIdentifier</key>
            <string>com.apple.MobileSMS</string>
            <key>Name</key>
            <string>Find Message</string>
            <key>AppIntentIdentifier</key>
            <string>MessageEntity</string>
        </dict>
        <key>WFContentItemFilter</key>
        <!-- filter conditions -->
        <key>WFContentItemSortProperty</key>
        <string>date</string>
        <key>WFContentItemSortOrder</key>
        <string>Latest First</string>
        <key>WFContentItemLimitEnabled</key>
        <true/>
        <key>WFContentItemLimitNumber</key>
        <integer>25</integer>
    </dict>
</dict>
```

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `WFContentItemFilter` | WFContentPredicateTableTemplate | Filter conditions |
| `WFContentItemSortProperty` | String | Sort by property |
| `WFContentItemSortOrder` | String | `Latest First` or `Oldest First` |
| `WFContentItemLimitEnabled` | Boolean | Enable result limit |
| `WFContentItemLimitNumber` | Integer | Max results |

### Message Entity Properties

Properties available for filtering and property access:

| Property | Description |
|----------|-------------|
| `body` | Message text content |
| `sender` | Message sender |
| `date` | Date sent/received |
| `subject` | Message subject (if any) |
| `conversation` | Parent conversation |
| `isUnread` | Whether message is unread |
| `messageType` | Type of message |
| `attributes` | Message attributes |
| `attachments` | Message attachments |
| `customAttachments` | Custom attachments |
| `locations` | Location data |
| `links` | URLs in message |
| `messageEffect` | iMessage effect |
| `reaction` | Reaction/tapback |

### Legacy WFMessageContentItem Properties

When using the older content item system:

| Property | Description |
|----------|-------------|
| `Content` | Message body text |
| `Recipients` | Message recipients |
| `Sender` | Message sender |
| `Name` | Display name |

---

## Find Conversation (com.apple.MobileSMS.ConversationEntity)

Find/filter message conversations (threads).

### Invocation

```xml
<dict>
    <key>WFWorkflowActionIdentifier</key>
    <string>is.workflow.actions.appintentexecution</string>
    <key>WFWorkflowActionParameters</key>
    <dict>
        <key>UUID</key>
        <string>FIND-CONV-UUID</string>
        <key>AppIntentDescriptor</key>
        <dict>
            <key>BundleIdentifier</key>
            <string>com.apple.MobileSMS</string>
            <key>Name</key>
            <string>Find Conversation</string>
            <key>AppIntentIdentifier</key>
            <string>ConversationEntity</string>
        </dict>
        <key>WFContentItemFilter</key>
        <!-- filter conditions -->
        <key>WFContentItemSortProperty</key>
        <string>dateLastActive</string>
        <key>WFContentItemSortOrder</key>
        <string>Latest First</string>
        <key>WFContentItemLimitEnabled</key>
        <true/>
        <key>WFContentItemLimitNumber</key>
        <integer>10</integer>
    </dict>
</dict>
```

### Conversation Entity Properties

| Property | Description |
|----------|-------------|
| `conversationName` | Conversation/group name |
| `displayName` | Display name |
| `participants` | Participants in the conversation |
| `previewText` | Last message preview |
| `isUnread` | Has unread messages |
| `attributes` | Conversation attributes |
| `dateLastActive` | Last activity date |

---

## Search For Messages: DEPRECATED

Legacy `INSearchForMessagesIntent`. Still works but Apple says "This action won't be supported in future versions of Shortcuts."

### Invocation (legacy SiriIntent style)

```xml
<dict>
    <key>WFWorkflowActionIdentifier</key>
    <string>is.workflow.actions.handleintent</string>
    <key>WFWorkflowActionParameters</key>
    <dict>
        <key>UUID</key>
        <string>SEARCH-MSG-UUID</string>
        <key>WFIntentDescriptor</key>
        <dict>
            <key>INIntentClassIdentifier</key>
            <string>INSearchForMessagesIntent</string>
            <key>BundleIdentifier</key>
            <string>com.apple.MobileSMS</string>
        </dict>
        <key>sender</key>
        <!-- contact reference -->
        <key>recipient</key>
        <!-- contact reference -->
        <key>dateTimeRange</key>
        <!-- date range -->
        <key>attribute</key>
        <!-- message attributes -->
    </dict>
</dict>
```

### Parameters

| Parameter | Description |
|-----------|-------------|
| `sender` | Filter by sender |
| `recipient` | Filter by recipient |
| `dateTimeRange` | Filter by date range |
| `attribute` | Filter by attribute (read/unread) |

---

## All Messages Actions

| ID | Name | Type |
|----|------|------|
| `com.apple.MobileSMS.MessageEntity` | Find Message | appIntent |
| `com.apple.MobileSMS.ConversationEntity` | Find Conversation | appIntent |
| `com.apple.MobileSMS.INSearchForMessagesIntent` | Search For Messages | siriIntent (deprecated) |
| `com.apple.MobileSMS.INSendMessageIntent` | Send Message | siriIntent (deprecated) |
| `com.apple.MobileSMS.INEditMessageIntent` | Edit Message | siriIntent (deprecated) |
| `com.apple.MobileSMS.INUnsendMessagesIntent` | Unsend Messages | siriIntent (deprecated) |
| `com.apple.MobileSMS.INSetMessageAttributeIntent` | Set Message Attribute | siriIntent (deprecated) |
| `com.apple.MobileSMS.SendReplyIntent` | Send Reply | appIntent |
| `com.apple.MobileSMS.DeleteMessageIntent` | Delete Message | appIntent |
| `com.apple.MobileSMS.DeleteConversationIntent` | Delete Conversation | appIntent |
| `com.apple.MobileSMS.OpenMessageIntent` | Reveal Message | appIntent |
| `com.apple.MobileSMS.OpenConversationIntent` | Open Conversation | appIntent |
| `com.apple.MobileSMS.OpenConversationListIntent` | Open Conversation List | appIntent |
| `com.apple.MobileSMS.ChangeFilterModeIntent` | Open Inbox | appIntent |
| `com.apple.MobileSMS.MarkConversationAsUnreadIntent` | Mark as Read | appIntent |
| `com.apple.MobileSMS.MuteConversationIntent` | Mute Conversation | appIntent |
| `com.apple.MobileSMS.SendTapbackIntent` | Send Tapback | appIntent |
| `com.apple.MobileSMS.RemoveTapbackIntent` | Remove Tapback | appIntent |
| `com.apple.MobileSMS.SendMessageReactionIntent` | Send Reaction | appIntent |
| `com.apple.MobileSMS.FetchConversationIdentifierIntent` | Fetch Conversation ID | appIntent |
| `com.apple.MobileSMS.FetchMutedConversationListIntent` | Fetch Muted Conversations | appIntent |
| `com.apple.MobileSMS.FetchDowntimeConversationListIntent` | Fetch Downtime Conversations | appIntent |
| `com.apple.MobileSMS.ConversationListFocusFilterAction` | Set Messages Focus Filter | appIntent |

---

## Common Patterns

### Find recent messages from a specific person

Use Find Message with a sender filter and date sort:

```xml
<dict>
    <key>WFWorkflowActionIdentifier</key>
    <string>is.workflow.actions.appintentexecution</string>
    <key>WFWorkflowActionParameters</key>
    <dict>
        <key>UUID</key>
        <string>AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA</string>
        <key>AppIntentDescriptor</key>
        <dict>
            <key>BundleIdentifier</key>
            <string>com.apple.MobileSMS</string>
            <key>Name</key>
            <string>Find Message</string>
            <key>AppIntentIdentifier</key>
            <string>MessageEntity</string>
        </dict>
        <key>WFContentItemFilter</key>
        <dict>
            <key>Value</key>
            <dict>
                <key>WFActionParameterFilterPrefix</key>
                <integer>1</integer>
                <key>WFContentPredicateBoundedDate</key>
                <false/>
                <key>WFActionParameterFilterTemplates</key>
                <array>
                    <dict>
                        <key>Operator</key>
                        <integer>4</integer>
                        <key>Property</key>
                        <string>sender</string>
                        <key>Removable</key>
                        <true/>
                        <key>Values</key>
                        <dict>
                            <key>String</key>
                            <string>John Smith</string>
                            <key>Unit</key>
                            <integer>4</integer>
                        </dict>
                    </dict>
                </array>
            </dict>
            <key>WFSerializationType</key>
            <string>WFContentPredicateTableTemplate</string>
        </dict>
        <key>WFContentItemSortProperty</key>
        <string>date</string>
        <key>WFContentItemSortOrder</key>
        <string>Latest First</string>
        <key>WFContentItemLimitEnabled</key>
        <true/>
        <key>WFContentItemLimitNumber</key>
        <integer>50</integer>
    </dict>
</dict>
```

### Get message body text for processing

Chain with a Get Property action to extract the body text:

```xml
<!-- After Find Message, get the body property -->
<dict>
    <key>WFWorkflowActionIdentifier</key>
    <string>is.workflow.actions.contentitem</string>
    <key>WFWorkflowActionParameters</key>
    <dict>
        <key>UUID</key>
        <string>BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB</string>
        <key>WFInput</key>
        <dict>
            <key>Value</key>
            <dict>
                <key>OutputUUID</key>
                <string>AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA</string>
                <key>OutputName</key>
                <string>Message</string>
                <key>Type</key>
                <string>ActionOutput</string>
                <key>Aggrandizements</key>
                <array>
                    <dict>
                        <key>PropertyName</key>
                        <string>body</string>
                        <key>Type</key>
                        <string>WFPropertyVariableAggrandizement</string>
                    </dict>
                </array>
            </dict>
            <key>WFSerializationType</key>
            <string>WFTextTokenAttachment</string>
        </dict>
    </dict>
</dict>
```
