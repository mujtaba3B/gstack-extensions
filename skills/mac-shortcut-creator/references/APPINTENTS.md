# Apple AppIntents Reference (Complete)

All 704 Apple AppIntents from the Shortcuts ToolKit database.
Excludes System Settings (573), Accessibility (29), Siri (27), Watch Settings (9) deep links.

## Invocation

AppIntents use `is.workflow.actions.appintentexecution`:

```xml
<dict>
    <key>WFWorkflowActionIdentifier</key>
    <string>is.workflow.actions.appintentexecution</string>
    <key>WFWorkflowActionParameters</key>
    <dict>
        <key>AppIntentDescriptor</key>
        <dict>
            <key>BundleIdentifier</key><string>BUNDLE_ID</string>
            <key>Name</key><string>DISPLAY_NAME</string>
            <key>AppIntentIdentifier</key><string>INTENT_ID</string>
        </dict>
    </dict>
</dict>
```


## AppKit (`com.apple.AppKit`)

| Intent ID | Name | Type |
|-----------|------|------|
| `FetchIntelligenceCommands` | Fetch Intelligence Commands | appIntent |
| `InsertIntelligenceText` | Insert Intelligence Text | appIntent |
| `RunIntelligenceCommand` | Run Intelligence Command | appIntent |
| `RunIntelligenceCommandForKey` | Run Intelligence Command For Key | appIntent |
| `WindowTabActivateIntent` | Activate Tab | appIntent |
| `WindowTabEntity` | Find Window Tab | appIntent |
| `WritingToolsComposeIntent` | Text Compose | appIntent |
| `WritingToolsProofreadIntent` | Proofread | appIntent |
| `WritingToolsRewriteIntent` | Rewrite | appIntent |

## Books (`com.apple.iBooksX`)

| Intent ID | Name | Type |
|-----------|------|------|
| `AudiobookSleepTimerIntent` | Set Audiobook Sleep Timer | appIntent |
| `BookAppEntity` | Find Books | appIntent |
| `BookReaderChangeThemeIntent` | Change Book Appearance | appIntent |
| `BookReaderNavigatePageInBookIntent` | Turn Page | appIntent |
| `BookReaderNavigatePagesIntent` | Turn Page | appIntent |
| `BookSettingsEntity` | Get Book Settings | appIntent |
| `BookSettingsEntity-UpdatableEntity` | Edit Book Settings | appIntent |
| `ChangeFontSizeIntent` | Change Text Size | appIntent |
| `CloseBookIntent` | Close Book | appIntent |
| `DeepLinkIntent` | Open View or Collection in Books App | appIntent |
| `DefaultCollectionEntity` | Find Standard Collection | appIntent |
| `OpenBookIntent` | Open Book | appIntent |
| `OpenDefaultCollectionIntent` | Open Default Collection | appIntent |
| `OpenMostRecentBookIntent` | Open Most Recent Book | appIntent |
| `OpenSpecificBookIntent` | Open Specific Book | appIntent |
| `OpenTabBarItemIntent` | Open View in Books App | appIntent |
| `OpenTableOfContentsIntent` | Open Table of Contents | appIntent |
| `PauseCurrentAudiobookIntent` | Pause Current Audiobook | appIntent |
| `PlayAudiobookIntent` | Play Audiobook | appIntent |
| `PlayMostRecentAudiobookIntent` | Play Most Recent Audiobook | appIntent |
| `PlaySpecificAudiobookIntent` | Play Specific Audiobook | appIntent |
| `SearchBooksAppIntent` | Search in the Books App | appIntent |
| `SearchBooksIntent` | Search in Books | appIntent |
| `UpdateBookSettingsIntent` | UpdateReaderIntent | appIntent |
| `openin` | Add PDF to Books | action |

## Calendar (`com.apple.iCal`)

| Intent ID | Name | Type |
|-----------|------|------|
| `CreateCalendarIntent` | Create Calendar | appIntent |
| `CreateEventIntent` | Create Event | appIntent |
| `CreateEventIntent_v0` | Create Event | appIntent |
| `DeleteCalendarsIntent` | Delete Calendars | appIntent |
| `DeleteEventIntent` | Delete Events | appIntent |
| `DeleteEventIntent_v0` | Delete Events | appIntent |
| `EditEventIntent` | Edit Event | appIntent |
| `EditEventIntent_v0` | Edit Event | appIntent |
| `EmailAttendeesIntent` | Email Attendees | appIntent |
| `EmailOrganizerIntent` | Email Organizer | appIntent |
| `EventEntity` | Find Event | appIntent |
| `FetchTransferableEventByURLIntent` | Fetch Transferable Event By URL Intent | appIntent |
| `FetchTransferableEventsInRangeIntent` | Fetch Transferable Events In Range Intent <no loc> | appIntent |
| `HighlightEventIntent` | Highlight Event | appIntent |
| `InboxItemEntity` | Find Inbox Item | appIntent |
| `JoinEventIntent` | Join Event | appIntent |
| `ListEventsIntent` | List Events Intent <no loc> | appIntent |
| `OpenCalendarEditorIntent` | Open Calendar Editor | appIntent |
| `OpenCalendarViewIntent` | Open Calendar View | appIntent |
| `OpenDateIntent` | Open Date | appIntent |
| `OpenEventDetailsIntent` | Open Event Details | appIntent |
| `OpenEventEditorIntent` | Open Event Editor | appIntent |
| `RespondToInboxItemIntent` | Respond to Inbox Item | appIntent |
| `SetCalendarFocusConfiguration` | Set Calendar Focus Filter | appIntent |
| `TransferableCalendarEntity` | Find TransferableCalendarEntity <no loc> | appIntent |
| `TransferableSourceEntity` | Find TransferableSourceEntity <no loc> | appIntent |

## Clock (`com.apple.clock`)

| Intent ID | Name | Type |
|-----------|------|------|
| `AddWorldClockIntent` | Add City | appIntent |
| `CancelTimerIntent` | Cancel Timer | appIntent |
| `DeleteAlarmIntent` | Delete Alarms | appIntent |
| `GetCurrentTimerDetailsIntent` | Get Current Timer | appIntent |
| `GetTimeForCityIntent` | Get Time for City | appIntent |
| `LapStopwatchIntent` | Lap Stopwatch | appIntent |
| `OpenAlarmIntent` | Opens Alarm | appIntent |
| `OpenTab` | Open Tab | appIntent |
| `OpenTabIntent` | Open Clock Tab | appIntent |
| `PauseTimerIntent` | Pause Timer | appIntent |
| `RemoveWorldClockIntent` | Remove City | appIntent |
| `ResetStopwatchIntent` | Reset Stopwatch | appIntent |
| `ResumeTimerIntent` | Resume Timer | appIntent |
| `StartStopwatchIntent` | Start Stopwatch | appIntent |
| `StopStopwatchIntent` | Stop the Stopwatch | appIntent |

## Contacts (`com.apple.AddressBook`)

| Intent ID | Name | Type |
|-----------|------|------|
| `ContactEntity` | Find Contact | appIntent |
| `CreateContactIntent` | Create Contact | appIntent |
| `DeleteContactIntent` | Delete Contact | appIntent |
| `FetchContactAvatarIntent` | Fetch Avatars for Contacts | appIntent |
| `FetchContactIntent` | Fetch Contacts | appIntent |
| `SearchInContactsIntent` | Search in Contacts App | appIntent |
| `UpdateContactIntent` | Update Contact Details | appIntent |
| `ViewContactCardIntent` | View Contact Card | appIntent |

## Finder (`com.apple.finder`)

| Intent ID | Name | Type |
|-----------|------|------|
| `CompressItemsIntent` | Compress Items | appIntent |
| `CopyItemsIntent` | Copy and Move Items | appIntent |
| `CreateFolderIntent` | New Folder | appIntent |
| `DuplicateItemsIntent` | Duplicate Items | appIntent |
| `GetInfoIntent` | Get Info | appIntent |
| `GetLocationIntent` | Get Location | appIntent |
| `GetSelectedItemsIntent` | Get Selected Items | appIntent |
| `GoToEnclosingFolderIntent` | Go To Enclosing Folder | appIntent |
| `GoToFolderIntent` | Go To Folder | appIntent |
| `GoToLocationIntent` | Go To Location | appIntent |
| `MoveItemsIntent` | Move Items to Folder | appIntent |
| `OpenItemIntent` | Open Item | appIntent |
| `RenameItemIntent` | Rename Item | appIntent |
| `RevealItemsIntent` | Reveal Items | appIntent |
| `SearchInBrowserIntent` | Search in Finder | appIntent |
| `TrashItemsIntent` | Trash Items | appIntent |

## Freeform (`com.apple.freeform`)

| Intent ID | Name | Type |
|-----------|------|------|
| `CRLAddItemToBoardIntent` | Add Item to Board | appIntent |
| `CRLAddStickyNoteToBoardIntent` | Add Sticky Note to Board | appIntent |
| `CRLAddTextToBoardIntent` | Add Text to Board | appIntent |
| `CRLChangeBoardCanvasGridIntent` | Show/Hide Dot Grid | appIntent |
| `CRLChangeBoardObjectConnectorsIntent` | Show/Hide Object Connectors | appIntent |
| `CRLChangeSelectionColorIntent` | Change Fill Color | appIntent |
| `CRLChangeSelectionFontSizeIntent` | Change Font Size | appIntent |
| `CRLChangeSelectionFontStyleIntent` | Change Font Style | appIntent |
| `CRLCreateBoardIntent` | Create Board | appIntent |
| `CRLDeleteBoardIntent` | Delete Boards | appIntent |
| `CRLFavoriteBoardIntent_v2` | Favorite/Unfavorite Board | appIntent |
| `CRLInsertFilesToBoardIntent` | Add Files to Board | appIntent |
| `CRLInsertPhotosToBoardIntent` | Add Photos to Board | appIntent |
| `CRLInsertShapeToBoardIntent` | Add Shape to Board | appIntent |
| `CRLInsertTextToBoardIntent` | Insert Text | appIntent |
| `CRLInsertURLToBoardIntent` | Add Link to Board | appIntent |
| `CRLOpenBoardIntent` | Open Board | appIntent |
| `CRLRenameBoardIntent` | Rename Board ⚠️ | appIntent |
| `CRLResizeSelectionFontIntent` | Resize Text ⚠️ | appIntent |
| `CRLResizeSelectionFontIntent_v2` | Resize Text | appIntent |
| `CRLUpdateBoardIntent` | Rename Board | appIntent |
| `CRLUtilitiesIntent` | Utilities Intent | appIntent |
| `CRLiOSCreateBoardIntent` | Create New Freeform Board ⚠️ | appIntent |
| `CRLiOSOpenBoardIntent` | Open Freeform Board ⚠️ | appIntent |

## Home (`com.apple.Home`)

| Intent ID | Name | Type |
|-----------|------|------|
| `ActivateSceneIntent` | Activate Scene | appIntent |
| `AutomateAttributeValueIntent` | Automate Set Attribute Value | appIntent |
| `AutomateSceneIntent` | Automate Scene | appIntent |
| `CameraClipEntity` | Find  | appIntent |
| `DeltaAttributeValueIntent` | Delta Attribute | appIntent |
| `DeviceEntity` | Find Device | appIntent |
| `ErrorIntent` | Error Intent | appIntent |
| `ForecastWidgetConfiguration` | Show the Grid Forecast for a Home or your location. | appIntent |
| `GetAttributeValueIntent` | Get Attribute | appIntent |
| `GetDeviceInfoIntent` | Get Device Info | appIntent |
| `HistoricalUsageWidgetConfiguration` | Select Home | appIntent |
| `HomeAppIntentsExtensionTestAppIntent` | HomeAppIntentsExtensionTestAppIntent | appIntent |
| `HomeEntity` | Find Selected Home | appIntent |
| `HomeSingleTileConfigurationIntent` | Scene or Accessory | appIntent |
| `HomeXLModuleConfigurationIntent` | Accessories | appIntent |
| `OpenURLInHomeIntent` | Open Accessory or Scene in Home app | appIntent |
| `RecommendedItemIntent` | Recommended Item | appIntent |
| `RoomEntity` | Find Room | appIntent |
| `SceneEntity` | Find Scene | appIntent |
| `SecureToggleIntent` | Toggle Accessory or Scene | appIntent |
| `SelectedHomeEntity` | Find Selected Home | appIntent |
| `SetAttributeValueIntent` | Set Attribute | appIntent |
| `ShowDeviceResultIntent` | Show Device Result | appIntent |
| `ShowErrorIntent` | Show Error | appIntent |
| `ShowNavigationIntent` | Show Navigation | appIntent |
| `ShowSceneResultIntent` | Show Scene Result | appIntent |
| `TileControlAction` | ToggleIntentTitle | appIntent |
| `ToggleAttributeIntent` | Toggle Attribute | appIntent |
| `ToggleControlConfigurationIntent` | Scene or Accessory | appIntent |
| `ToggleIntent` | Toggle Accessory or Scene | appIntent |
| `UtilityRateInfoWidgetConfiguration` | Select Home | appIntent |
| `ZoneEntity` | Find Zone | appIntent |

## Journal (`com.apple.journal`)

| Intent ID | Name | Type |
|-----------|------|------|
| `AddCurrentLocationEntity` | Get Add Current Location | appIntent |
| `AddCurrentLocationEntity-UpdatableEntity` | Update Add Current Location | appIntent |
| `AddCurrentLocationIntent` | Open Add Current Location Setting | appIntent |
| `AlwaysUseMomentDateEntity` | Get Always Use Moment Date | appIntent |
| `AlwaysUseMomentDateEntity-UpdatableEntity` | Update Always Use Moment Date | appIntent |
| `AlwaysUseMomentDateIntent` | Open Always Use Moment Date Setting | appIntent |
| `CreateEntryAudioIntent` | Create Audio Entry | appIntent |
| `CreateEntryIntent` | Create Entry | appIntent |
| `OpenEntryEntityIntent` | Open Entry | appIntent |
| `OpenJournalSettingsDeeplinks` | Open Journal Settings | appIntent |
| `RefreshIntent` | StartWritingRefreshIntent | appIntent |
| `SaveToPhotosEntity` | Get Save To Photos | appIntent |
| `SaveToPhotosEntity-UpdatableEntity` | Update Save To Photos | appIntent |
| `SaveToPhotosIntent` | Open Save to Photos Setting | appIntent |
| `SearchEntriesIntent` | Search Entries | appIntent |
| `SkipJournalingSuggestionsEntity` | Get Show Suggested Moments | appIntent |
| `SkipJournalingSuggestionsEntity-UpdatableEntity` | Update Show Suggested Moments | appIntent |
| `SkipJournalingSuggestionsIntent` | Open Show Suggested Moments Setting | appIntent |
| `StreaksWidgetConfigurationIntent` | Streaks | appIntent |

## Magnifier (`com.apple.Magnifier`)

| Intent ID | Name | Type |
|-----------|------|------|
| `DescribeThisIntent` | Describe This | appIntent |
| `DetectDoorsIntent` | Detect Doors | appIntent |
| `DetectFurnitureIntent` | Detect Furniture | appIntent |
| `DetectPeopleIntent` | Detect People | appIntent |
| `DetectTextIntent` | Detect Text | appIntent |
| `MagnifierIntent` | Magnifier | appIntent |
| `PointAndSpeakIntent` | Start Point & Speak | appIntent |
| `ReaderModeIntent` | Open Reader | appIntent |
| `StartDetectionTypeIntent` | Detect Items | appIntent |

## Mail (`com.apple.mail`)

| Intent ID | Name | Type |
|-----------|------|------|
| `ArchiveMessageIntent` | Archive Message | appIntent |
| `BlockSenderIntent` | Block Sender | appIntent |
| `CancelDraftIntent` | Cancel Draft | appIntent |
| `ComposeMessageIntent` | Compose Message | appIntent |
| `DeleteDraftIntent` | Delete Draft | appIntent |
| `DeleteMessageIntent` | Delete Message | appIntent |
| `DeleteReadLaterIntent` | Delete Read Later | appIntent |
| `ForwardMessageIntent` | Forward Message | appIntent |
| `MailFocusConfigurationAction` | Set Mail Focus Filter | appIntent |
| `MailMessage` | Find Message | appIntent |
| `MailMessageEntity` | Find Message | appIntent |
| `MuteThreadIntent` | Mute Thread | appIntent |
| `OpenDraftIntent` | Open Draft | appIntent |
| `OpenDraftURLIntent` | Open Draft | appIntent |
| `OpenMessageURLIntent` | Open Message | appIntent |
| `RemoveFollowUpIntent` | Remove Follow Up | appIntent |
| `ReplyMessageIntent` | Reply Message | appIntent |
| `SaveDraftIntent` | Save Draft | appIntent |
| `SearchMailIntent` | Search | appIntent |
| `SendDraftIntent` | Send Draft | appIntent |
| `SendMail` | Send an Email | appIntent |
| `SetMailMessageIsRead` | Mark Email Read | appIntent |
| `SetReadLaterIntent` | Set Read Later | appIntent |
| `SummarizeThreadIntent` | Summarize Thread | appIntent |
| `UndoSendMessageIntent` | Undo Send Message | appIntent |
| `UnsubscribeMessageIntent` | Unsubscribe Message | appIntent |
| `UpdateDraftIntent` | Update Draft | appIntent |
| `UpdateMessageIntent` | Update Message | appIntent |

## Messages (`com.apple.MobileSMS`)

| Intent ID | Name | Type |
|-----------|------|------|
| `ChangeFilterModeIntent` | Open Inbox | appIntent |
| `ConversationEntity` | Find Conversation | appIntent |
| `ConversationListFocusFilterAction` | Set Messages Focus Filter | appIntent |
| `DeleteConversationIntent` | Delete Conversation | appIntent |
| `DeleteMessageIntent` | Delete Message | appIntent |
| `FetchConversationIdentifierIntent` | Fetch Conversation Identifier Intent | appIntent |
| `FetchDowntimeConversationListIntent` | Fetch Downtime Conversation List Intent | appIntent |
| `FetchMutedConversationListIntent` | Fetch Muted Conversation List Intent | appIntent |
| `INEditMessageIntent` | Edit Message ⚠️ | siriIntent |
| `INSearchForMessagesIntent` | Search For Messages ⚠️ | siriIntent |
| `INSendMessageIntent` | Send Message ⚠️ | siriIntent |
| `INSetMessageAttributeIntent` | Set Message Attribute ⚠️ | siriIntent |
| `INUnsendMessagesIntent` | Unsend Messages ⚠️ | siriIntent |
| `MarkConversationAsUnreadIntent` | Mark as Read | appIntent |
| `MessageEntity` | Find Message | appIntent |
| `MuteConversationIntent` | Mute Conversation Intent | appIntent |
| `OpenConversationIntent` | Open Conversation | appIntent |
| `OpenConversationListIntent` | Open Conversation List | appIntent |
| `OpenMessageIntent` | Reveal Message | appIntent |
| `RemoveTapbackIntent` | Remove Tapback | appIntent |
| `SendMessageReactionIntent` | Send Message Reaction | appIntent |
| `SendReplyIntent` | Send Reply | appIntent |
| `SendTapbackIntent` | Send Tapback | appIntent |

## News (`com.apple.news`)

| Intent ID | Name | Type |
|-----------|------|------|
| `BlockIntent` | Block Channel or Topic | appIntent |
| `DecreaseTextSizeIntent` | Decrease Text Size | appIntent |
| `FollowIntent` | Follow Channel or Topic | appIntent |
| `GameCenterEntity` | Get Game Center | appIntent |
| `GameCenterEntity-UpdatableEntity` | Update Game Center | appIntent |
| `INPlayMediaIntent` | Play Media ⚠️ | siriIntent |
| `IncreaseTextSizeIntent` | Increase Text Size | appIntent |
| `NewsSettingsAutomaticDownloadDynamicDeepLinks` | Find News Automatic Download Settings | appIntent |
| `NewsSettingsDynamicDeepLinks` | Find News Settings | appIntent |
| `NewsTabDeepLink` | Find News Tab Deep Links | appIntent |
| `OpenArticleIntent` | Open Article | appIntent |
| `OpenFeedIntent` | Open Channel or Topic | appIntent |
| `OpenHistoryIntent` | Open History Feed | appIntent |
| `OpenRecipeIntent` | Open Recipe | appIntent |
| `OpenSavedIntent` | Open Saved Feed | appIntent |
| `OpenSavedRecipesIntent` | Open Saved Recipes | appIntent |
| `OpenStaticFeed` | Open News Feed | appIntent |
| `RestrictStoriesInTodaySettingEntity` | Get Restrict Stories in Today | appIntent |
| `RestrictStoriesInTodaySettingEntity-UpdatableEntity` | Update Restrict Stories in Today | appIntent |
| `SaveArticleIntent` | Save Article | appIntent |
| `TagIntent` | Show Topic | siriIntent |
| `TodayIntent` | Show Today Feed | siriIntent |
| `ToggleAudioPlaybackIntent` | Play Audio Article | appIntent |
| `UnblockIntent` | Unblock Channel or Topic | appIntent |
| `UnsaveArticleIntent` | Unsave Article | appIntent |
| `WFAppSettingEntityUpdaterAction` | Change News Settings | appIntent |
| `WFGetAppSettingAction` | Get News Settings | appIntent |

## Notes (`com.apple.Notes`)

| Intent ID | Name | Type |
|-----------|------|------|
| `AddFileAttachmentLinkAction` | Add File to Note | appIntent |
| `AddLinkAttachmentLinkAction` | Add Link | appIntent |
| `AddOrRemoveNoteLockLinkAction` | Add or Remove Note Lock | appIntent |
| `AddTagsToNotesLinkAction` | Add Tags to Notes | appIntent |
| `AppendMarkdownToNoteLinkAction` | Append Markdown to Note | appIntent |
| `ApplyFormattingLinkAction` | Apply Formatting to Selected Text | appIntent |
| `AttachmentEntity` | Find Attachment | appIntent |
| `ChangeFolderSettingLinkAction` | Change Folder View Setting | appIntent |
| `ChangeSettingLinkAction` | Change Notes Setting | appIntent |
| `ChangeTagSelectionIntent` | Change Tag Selection | appIntent |
| `CloseAppLocationLinkAction` | Close Notes View | appIntent |
| `CloseNoteLinkAction` | Close Note | appIntent |
| `CreateChecklistItemLinkAction` | Append Checklist Item | appIntent |
| `CreateFolderLinkAction` | Create Folder | appIntent |
| `CreateNoteFromMarkdownLinkAction` | Create Note from Markdown | appIntent |
| `CreateTableLinkAction` | Add Table to Note | appIntent |
| `CreateTagLinkAction` | Create Tag | appIntent |
| `DeleteAttachmentsLinkAction` | Delete Attachments | appIntent |
| `DeleteChecklistItemsLinkAction` | Delete Checklist Items | appIntent |
| `DeleteFoldersLinkAction` | Delete Folders | appIntent |
| `DeleteNotesLinkAction` | Delete Notes | appIntent |
| `DeleteTablesLinkAction` | Delete Tables | appIntent |
| `DeleteTagsLinkAction` | Delete Tags | appIntent |
| `GetLinkedNotesLinkAction` | Get Linked Notes | appIntent |
| `ICNotesFolderIntent` | Show Notes Folder | siriIntent |
| `INCreateNoteIntent` | Create Note ⚠️ | siriIntent |
| `InsertAllMentionLinkAction` | Insert All Mention | appIntent |
| `InsertMentionLinkAction` | Insert Mention | appIntent |
| `InsertNoteLinkLinkAction` | Insert Note Link | appIntent |
| `MoveNotesToFolderLinkAction` | Move Notes to Folder | appIntent |
| `OpenAccountLinkAction` | Open Account | appIntent |
| `OpenAppLocationLinkAction` | Open Notes View | appIntent |
| `OpenAttachmentLinkAction` | Open Attachment | appIntent |
| `OpenChecklistItemLinkAction` | Reveal Checklist Item | appIntent |
| `OpenFolderLinkAction` | Open Folder | appIntent |
| `OpenTableLinkAction` | Reveal Table | appIntent |
| `OpenTagLinkAction` | Open Tag | appIntent |
| `OpenTopLevelFolderLinkAction` | Open Top-Level Folder | appIntent |
| `PinNotesLinkAction` | Pin Notes | appIntent |
| `QuickNoteIntent` | Quick Note | appIntent |
| `RemoveTagsFromNotesLinkAction` | Remove Tags from Notes | appIntent |
| `RenameFolderLinkAction` | Rename Folder | appIntent |
| `ReplaceSelectionLinkAction` | Replace Selected Text | appIntent |
| `SetAttachmentSizeLinkAction` | Set Attachment Size | appIntent |
| `SetChecklistItemCheckedLinkActionv2` | Set Checklist Items Checked | appIntent |
| `SetParagraphStyleLinkAction` | Set Paragraph Style | appIntent |
| `ShowNotesAppSearchResultsLinkAction` | Show Note and Attachment Search Result | appIntent |
| `ShowQuickNoteIntent` | Show Quick Note | appIntent |
| `StartRecordingLinkAction` | Start Audio Recording | appIntent |
| `TableEntity` | Find Table | appIntent |

## Photos (`com.apple.Photos`)

| Intent ID | Name | Type |
|-----------|------|------|
| `AddAssetsToAlbumIntent` | Add Photos To Album | appIntent |
| `ApplyFilterIntent` | Apply Filter | appIntent |
| `ApplyStyleIntent` | Apply Style | appIntent |
| `CleanupIntent` | Clean Up | appIntent |
| `CopyEditsIntent` | Copy Edits | appIntent |
| `CreateAlbumIntent` | Create Album | appIntent |
| `CreateAssetsIntent` | Save to Photos | appIntent |
| `CropIntent` | Crop | appIntent |
| `DeleteAlbumsIntent` | Delete Albums | appIntent |
| `DeleteAssetsIntent` | Delete Photos | appIntent |
| `DuplicateAssetsIntent` | Duplicate Photos | appIntent |
| `EditAssetIntent` | Edit Photo | appIntent |
| `EnableDepthIntent` | Portrait Mode | appIntent |
| `EnhanceIntent` | Auto Enhance | appIntent |
| `FavoriteAssetsIntent` | Favorite Photos | appIntent |
| `FavoriteMemoriesIntent` | Favorite Memories | appIntent |
| `FavoritePeopleIntent` | Favorite People or Pets | appIntent |
| `FilterLibraryIntent` | Set Library View | appIntent |
| `HideAssetsIntent` | Hide Photos | appIntent |
| `HidePeopleIntent` | Hide People or Pets | appIntent |
| `MarkupIntent` | Markup | appIntent |
| `MoveAssetsToPersonalLibraryIntent` | Move to Personal Library | appIntent |
| `MoveAssetsToSharedLibraryIntent` | Move to Shared Library | appIntent |
| `OpenAlbumIntent` | Open Album | appIntent |
| `OpenAssetIntent` | Open Photo | appIntent |
| `OpenDestinationIntent` | Open View | appIntent |
| `OpenMemoryCreationViewIntent` | Create Memory | appIntent |
| `OpenMemoryIntent` | Open Memory | appIntent |
| `OpenPersonIntent` | Open Person | appIntent |
| `PLPhotosReliveWidgetConfigurationIntent` | Photos Relive Widget Configuration | appIntent |
| `PasteEditsIntent` | Paste Edits | appIntent |
| `PhotosAddAssetsToAlbumAssistantIntent` | Add Photos to Album | appIntent |
| `PhotosCleanupPhotoAssistantIntent` | Cleanup | appIntent |
| `PhotosCopyEditsAssistantIntent` | Copy Edits | appIntent |
| `PhotosCreateAlbumAssistantIntent` | Create Album | appIntent |
| `PhotosCreateAssetsAssistantIntent` | Create Photos | appIntent |
| `PhotosCropAssistantIntent` | Crop Photo | appIntent |
| `PhotosDeleteAlbumsAssistantIntent` | Delete Albums | appIntent |
| `PhotosDeleteAssetsAssistantIntent` | Delete Photos | appIntent |
| `PhotosDuplicateAssetsAssistantIntent` | Duplicate Photos | appIntent |
| `PhotosPasteEditsAssistantIntent` | Paste Edits | appIntent |
| `PhotosReliveWidgetFeaturedConfiguration` | Photos Relive Featured Widget Configuration | appIntent |
| `PhotosRemoveAssetsFromAlbumAssistantIntent` | Remove Photos from Album | appIntent |
| `PhotosSearchAssistantIntent` | Search Photos | appIntent |
| `PhotosSetDepthAssistantIntent` | Set Depth | appIntent |
| `PhotosSetExposureAssistantIntent` | Set Exposure | appIntent |
| `PhotosSetFilterAssistantIntent` | Apply Filter | appIntent |
| `PhotosSetRotationAssistantIntent` | Rotate Photo | appIntent |
| `PhotosSetSaturationAssistantIntent` | Set Saturation | appIntent |
| `PhotosSetWarmthAssistantIntent` | Set Warmth | appIntent |
| `PhotosStraightenAssistantIntent` | Straighten Photo | appIntent |
| `PhotosToggleDepthAssistantIntent` | Toggle Depth | appIntent |
| `PhotosToggleSuggestedEditsAssistantIntent` | Enhance Photo | appIntent |
| `PhotosUpdateAlbumAssistantIntent` | Rename Album | appIntent |
| `PhotosUpdateAssetAssistantIntent` | Update Photo | appIntent |
| `PhotosUpdateRecognizedPersonAssistantIntent` | Update Person | appIntent |
| `RemoveAssetsFromAlbumIntent` | Remove Photos From Album | appIntent |
| `RenameAlbumIntent` | Rename Album | appIntent |
| `RenamePersonIntent` | Rename Person | appIntent |
| `RevealAlbumsIntent` | REVEAL_ALBUMS_INTENT_TITLE | appIntent |
| `RevealAssetsIntent` | REVEAL_ASSETS_INTENT_TITLE | appIntent |
| `RotateIntent` | Rotate | appIntent |
| `SetApertureIntent` | Set Aperture | appIntent |
| `SetAudioMixIntent` | Set Audio Mix | appIntent |
| `SetExposureIntent` | Set Exposure | appIntent |
| `SetPlaybackRateIntent` | Set Playback Speed | appIntent |
| `SetSaturationIntent` | Set Saturation | appIntent |
| `SetWarmthIntent` | Set Warmth | appIntent |
| `StraightenIntent` | Straighten | appIntent |

## Podcasts (`com.apple.podcasts`)

| Intent ID | Name | Type |
|-----------|------|------|
| `DownloadEpisodesAppIntent` | Download Episodes | appIntent |
| `FetchShowLatestEpisodesAppIntent` | Latest Episodes | appIntent |
| `FollowRSSFeedAppIntent` | Follow Podcast URL | appIntent |
| `FollowShowAppIntent` | Follow Show | appIntent |
| `MarkEpisodeAsPlayedAppIntent` | Mark Episode as Played | appIntent |
| `MarkEpisodeAsUnplayedAppIntent` | Mark Episode as Unplayed | appIntent |
| `OpenAppLocationAppIntent` | Open App Location | appIntent |
| `OpenChannelAppIntent` | Open Channel | appIntent |
| `OpenEpisodeAppIntent` | Open Episode | appIntent |
| `OpenShowAppIntent` | Open Show | appIntent |
| `PlayAudioIntent` | Play Episode | appIntent |
| `PlayEpisodeAppIntent` | Play Episode | appIntent |
| `PlayEpisodeLastAppIntent` | Play Episode Last | appIntent |
| `PlayEpisodeNextAppIntent` | Add Episode to Queue | appIntent |
| `PlayNextChapterAppIntent` | Play Next Chapter | appIntent |
| `PlayPauseStationAppIntent` | Play or Pause Station | appIntent |
| `PlayPauseWidgetIntent` | Play or Pause Episode | appIntent |
| `PlayPreviousChapterAppIntent` | Return to Previous Chapter | appIntent |
| `PlayStationAppIntent` | Play Station | appIntent |
| `RemoveEpisodesDownloadAppIntent` | Remove Downloads | appIntent |
| `SaveEpisodeAppIntent` | Save Episodes | appIntent |
| `SearchPodcastsAppIntent` | Search Podcasts | appIntent |
| `SelectLibraryListAppIntent` | Select a Library List | appIntent |
| `SelectWidgetShowAppIntent` | Select a Podcast Show | appIntent |
| `UnfollowShowAppIntent` | Unfollow Show | appIntent |
| `UnsaveEpisodeAppIntent` | Unsave Episodes | appIntent |
| `ViewTranscriptAppIntent` | View Transcript | appIntent |

## Preview (`com.apple.Preview`)

| Intent ID | Name | Type |
|-----------|------|------|
| `AutoEnhanceIntent` | Enhance Documents | appIntent |
| `BookmarkIntent` | Bookmark Pages | appIntent |
| `CloseIntent` | Close Documents | appIntent |
| `DeletePageIntent` | Delete Pages | appIntent |
| `DocumentEntity` | Find Document | appIntent |
| `ExportIntent` | Export Documents | appIntent |
| `FlipIntent` | Flip Documents | appIntent |
| `GetPagesIntent` | Get Pages in Documents | appIntent |
| `InsertPageIntent` | Insert Page | appIntent |
| `OpenIntent` | Open Documents | appIntent |
| `RemoveBackgroundIntent` | Remove Image Background in Documents | appIntent |
| `ResizeIntent` | Resize Documents | appIntent |
| `RevealDocumentIntent` | Reveal Document | appIntent |
| `RevealPageIntent` | Open Page | appIntent |
| `RotateIntent` | Rotate Documents | appIntent |
| `RotatePageIntent` | Rotate Pages | appIntent |
| `SaveIntent` | Save Documents | appIntent |
| `SearchIntent` | Search Documents | appIntent |

## Reminders (`com.apple.reminders`)

| Intent ID | Name | Type |
|-----------|------|------|
| `AddOrRemoveTagsAppIntent` | Add or Remove Tags | appIntent |
| `CompleteReminderAppIntent` | Set Reminder completion state | appIntent |
| `CompleteRemindersAppIntent` | Set Reminders completion state <no loc> | appIntent |
| `CreateCustomSmartListAppIntent` | Open New Custom Smart List | appIntent |
| `CreateGroupAppIntent` | Create Group | appIntent |
| `CreateSectionAppIntent` | Create Section | appIntent |
| `DeleteListsAppIntent` | Delete Lists | appIntent |
| `DeleteRemindersAppIntent` | Delete Reminders and Subtasks | appIntent |
| `DeleteRemindersListGroupsAppIntent` | Delete Groups | appIntent |
| `DeleteSectionsAppIntent` | Delete Sections | appIntent |
| `GroupEntity-UpdatableEntity` | Change Reminders Group Name | appIntent |
| `INAddTasksIntent` | Add Tasks ⚠️ | siriIntent |
| `INSetTaskAttributeIntent` | Set Task Attribute ⚠️ | siriIntent |
| `ListEntity-UpdatableEntity` | Edit Reminders List | appIntent |
| `MoveRemindersAppIntent` | Move Reminders | appIntent |
| `MoveRemindersToListAppIntent` | Move Reminders to a Reminders List <no loc> | appIntent |
| `MoveRemindersToParentReminderAppIntent` | Move Reminders to become Subtasks of a Parent Reminder <no loc> | appIntent |
| `MoveRemindersToSectionAppIntent` | Move Reminders to a Reminders List Section <no loc> | appIntent |
| `OpenGroupAppIntent` | Open Group | appIntent |
| `OpenReminderAppIntent` | Open Reminder In List | appIntent |
| `OpenSectionAppIntent` | Reveal Section In List | appIntent |
| `OpenSmartListAppIntent` | Open Smart List | appIntent |
| `OpenTagsAppIntent` | Open Tag Browser | appIntent |
| `RemotePreferencesEntity` | Get User Defaults Entity | appIntent |
| `SectionEntity-UpdatableEntity` | Edit Reminders List Section | appIntent |
| `SmartListEntity` | Find Smart List | appIntent |
| `TTRCreateListAppIntent` | Create List | appIntent |
| `TTRCreateReminderAppIntent` | Create Reminder | appIntent |
| `TTROpenListAppIntent` | Open List | appIntent |
| `TTROpenSmartListAppIntent` | Open List | appIntent |
| `TTRReminderSetCompletedIntent` | Toggle Reminder completion | appIntent |
| `TTRSearchRemindersAppIntent` | Search in Reminders | appIntent |
| `UpdateGroupAppIntent` | Update reminders group properties | appIntent |
| `UpdateListAppIntent` | Update reminders list properties | appIntent |
| `UpdateReminderAppIntent` | Update Reminder properties <no loc> | appIntent |
| `UpdateSectionAppIntent` | Update section properties | appIntent |
| `UpdateSmartListAppIntent` | Update reminders system smart list properties | appIntent |
| `UpdateSmartListIsHiddenAppIntent` | Show/Hide Reminders System Smart List | appIntent |

## Safari (`com.apple.Safari`)

| Intent ID | Name | Type |
|-----------|------|------|
| `BookmarkEntity` | Find Bookmarks | appIntent |
| `BookmarkTabIntent` | Bookmark Tab | appIntent |
| `BookmarkURLIntent` | Bookmark URL | appIntent |
| `CloseTab` | Close Tab | appIntent |
| `CloseTabsAssistantIntent` | Close Tabs | appIntent |
| `CloseView` | Close View | appIntent |
| `CloseWindowsIntent` | Close Windows | appIntent |
| `CreateNewBookmark` | Add Bookmark | appIntent |
| `CreateNewTab` | Create New Tab | appIntent |
| `CreateNewTabGroup` | Create Tab Group | appIntent |
| `CreateNewWindow` | Create Window | appIntent |
| `CreateTabAssistantIntent` | Create Tab | appIntent |
| `DeleteBookmarks` | Delete Bookmarks | appIntent |
| `DeleteTabGroups` | Delete Tab Groups | appIntent |
| `FindOnPage` | Find on Page | appIntent |
| `LoadURLInTab` | Open Link | appIntent |
| `MoveTabsToTabGroup` | Move Tabs to Tab Group | appIntent |
| `MoveTabsToWindowIntent` | Move Tabs to Window | appIntent |
| `OpenBookmark` | Open Bookmark | appIntent |
| `OpenBookmarkAssistantIntent` | Open Bookmark | appIntent |
| `OpenTab` | Switch Tab | appIntent |
| `OpenTabGroup` | Open Tab Group | appIntent |
| `OpenTabGroupForFocus` | Set Safari Focus Filter | appIntent |
| `OpenView` | Open View | appIntent |
| `QuickWebsiteSearchIntent` | Search Website | appIntent |
| `QuickWebsiteSearchProviderEntity` | Find browser_SearchableWebsiteEntity_1.0.0_entity_type_display_representation | appIntent |
| `SearchTabs` | Search Tabs | appIntent |
| `ShowWindowIntent` | Show Window | appIntent |
| `TabEntity` | Find Tabs | appIntent |
| `TabGroupEntity` | Find Tab Groups | appIntent |
| `WindowEntity` | Find Window | appIntent |

## Screenshots (`com.apple.screenshot.launcher`)

| Intent ID | Name | Type |
|-----------|------|------|
| `CaptureScreenIntent` | Capture Screen | appIntent |
| `CaptureSelectionIntent` | Capture Selection | appIntent |
| `CustomCaptureConfiguration` | Capture Configuration | appIntent |
| `CustomCaptureIntent` | Custom Capture | appIntent |
| `CustomRecordConfiguration` | Screen Recording Configuration | appIntent |
| `CustomRecordIntent` | Custom Capture | appIntent |
| `RecordScreenIntent` | Record Screen | appIntent |
| `RecordSelectionIntent` | Record Selection | appIntent |

## Shortcuts (`com.apple.shortcuts`)

| Intent ID | Name | Type |
|-----------|------|------|
| `AddShortcutToHomeScreenAction` | Add Shortcut to Home Screen | appIntent |
| `ChangeShortcutIconAction` | Change Shortcut Icon | appIntent |
| `CreateFolderAction` | Create Folder | appIntent |
| `CreateShortcutiCloudLinkAction` | Create iCloud Link for Shortcut | appIntent |
| `CreateWorkflowAction` | Create Shortcut | appIntent |
| `DeleteWorkflowAction` | Delete Shortcuts | appIntent |
| `GetShortcutAttributesAction` | Get Shortcut Attributes | appIntent |
| `MoveShortcutToFolderAction` | Move Shortcut | appIntent |
| `OpenAppIntent` | Open App | appIntent |
| `OpenNavigationDestinationAction` | Open Folder | appIntent |
| `OpenShortcutsStaticDeepLinks` | Open Shortcuts Settings | appIntent |
| `OpenWorkflowAction` | Open Shortcut | appIntent |
| `RenameShortcutAction` | Rename Shortcut | appIntent |
| `RunShortcutConfigurationIntent` | Shortcut | appIntent |
| `RunShortcutFromCollectionIntent` | Run Shortcut from Folder | appIntent |
| `RunShortcutIntent` | Run Shortcut | appIntent |
| `SearchActionDrawerAction` | Search Shortcuts Actions | appIntent |
| `SearchShortcutsAction` | Search in Shortcuts | appIntent |
| `SetShortcutAttributesAction` | Set Shortcut Attributes | appIntent |
| `ShortcutsFolderConfigurationIntent` | Shortcuts Folder | appIntent |
| `StopWorkflowAction` | Stop Shortcut | appIntent |

## Shortcuts Actions (`com.apple.ShortcutsActions`)

| Intent ID | Name | Type |
|-----------|------|------|
| `CellularPlanEntity` | Find Cellular Plan | appIntent |
| `GetOrientationAction` | Get Orientation | appIntent |
| `GetPhysicalActivity` | Get Physical Activity | appIntent |
| `PlayMusicTopHitAction` | Play Music | appIntent |
| `PlayPodcastTopHitAction` | Play Podcast | appIntent |
| `ResetCellularDataStatisticsAction` | Reset Cellular Data Statistics | appIntent |
| `SetDataRoamingAction` | Set Data Roaming | appIntent |
| `SetDefaultCellularPlanAction` | Set Default Line | appIntent |
| `SetSilentModeAction` | Set Silent Mode | appIntent |
| `SetVoiceDataModeAction` | Set Voice & Data | appIntent |
| `ShowControlCenterAction` | Show Control Center | appIntent |
| `StartCallTopHitAction` | Start Call | appIntent |
| `StartFaceTimeAudioCallTopHitAction` | Start FaceTime Audio Call | appIntent |
| `StartFaceTimeCallTopHitAction` | Start Call | appIntent |
| `StartFaceTimeVideoCallTopHitAction` | Start FaceTime Video Call | appIntent |
| `TimeMachineAction` | Start Time Machine Backup | appIntent |
| `ToggleCellularPlanAction` | Toggle Cellular Plan | appIntent |
| `TranscribeAudioAction` | Transcribe Audio | appIntent |

## Spotlight/Search (`com.apple.omniSearch.SearchToolExtension`)

| Intent ID | Name | Type |
|-----------|------|------|
| `OpenFlightReservationEntityIntent` | Open Flight Reservation Entity | appIntent |
| `OpenGenericEventEntityIntent` | Open Generic Event Entity | appIntent |
| `OpenHotelReservationEntityIntent` | Open Hotel Reservation Entity | appIntent |
| `OpenIDCardBusinessEntityIntent` | Open Business ID Card Entity | appIntent |
| `OpenIDCardPersonalEntityIntent` | Open Personal ID Card Entity | appIntent |
| `OpenMediaEntityIntent` | Open Media Entity | appIntent |
| `OpenRestaurantReservationEntityIntent` | Open Restaurant Reservation Entity | appIntent |
| `OpenSearchSpotlightEntityIntent` | Open Search Spotlight Entity | appIntent |
| `OpenTicketedShowEntityIntent` | Open Ticketed Show Entity | appIntent |
| `OpenTicketedTransportationEntityIntent` | Open Ticketed Transportation Entity | appIntent |
| `OpenVehicleReservationEntityIntent` | Open Vehicle Reservation Entity | appIntent |
| `SearchTool` | Search | appIntent |
| `SearchToolControl` | SearchTool Control | appIntent |
| `SearchToolMCGrounding` | Search Tool Memory Creation Grounding | appIntent |
| `SearchToolMCQU` | SearchTool MC QU | appIntent |

## Stocks (`com.apple.stocks`)

| Intent ID | Name | Type |
|-----------|------|------|
| `AddSymbolToWatchlistIntent` | Add Symbol to Watchlist | appIntent |
| `BlockIntent` | Block Channel or Topic | appIntent |
| `DecreaseTextSizeIntent` | Decrease Text Size | appIntent |
| `DeleteSymbolFromWatchlistIntent` | Delete Symbol from Watchlist | appIntent |
| `DeleteWatchlistsIntent` | Delete Watchlist | appIntent |
| `FollowIntent` | Follow Channel or Topic | appIntent |
| `GetSymbolQuoteIntent` | Get Symbol Quote | appIntent |
| `IncreaseTextSizeIntent` | Increase Text Size | appIntent |
| `NewWatchlistIntent` | Create Watchlist | appIntent |
| `NewsTabDeepLink` | Find News Tab Deep Links | appIntent |
| `OpenArticleIntent` | Open Article | appIntent |
| `OpenBusinessNewsIntent` | Open Business News | appIntent |
| `OpenFeedIntent` | Open Channel or Topic | appIntent |
| `OpenHistoryIntent` | Open History Feed | appIntent |
| `OpenRecipeIntent` | Open Recipe | appIntent |
| `OpenSavedIntent` | Open Saved Feed | appIntent |
| `OpenSavedRecipesIntent` | Open Saved Recipes | appIntent |
| `OpenStaticFeed` | Open News Feed | appIntent |
| `OpenSymbolIntent` | Open Symbol | appIntent |
| `OpenWatchlistIntent` | Open Watchlist | appIntent |
| `SaveArticleIntent` | Save Article | appIntent |
| `StockIntent` | Show Symbol Price | appIntent |
| `StocksOverviewIntent` | Show Watchlist | appIntent |
| `SymbolEntity` | Find Symbol | appIntent |
| `SymbolWidgetEntity` | Find Symbol | appIntent |
| `UnblockIntent` | Unblock Channel or Topic | appIntent |
| `UnsaveArticleIntent` | Unsave Article | appIntent |
| `WatchlistEntity` | Find Watchlist | appIntent |

## Voice Memos (`com.apple.VoiceMemos`)

| Intent ID | Name | Type |
|-----------|------|------|
| `AudioQualityEntity` | Get Audio Quality | appIntent |
| `AudioQualityEntity-UpdatableEntity` | Edit Audio Quality | appIntent |
| `ChangeRecordingPlaybackSetting` | Change Recording Playback Setting | appIntent |
| `ClearDeletedEntity` | Get Clear Deleted | appIntent |
| `ClearDeletedEntity-UpdatableEntity` | Edit Clear Deleted | appIntent |
| `CreateFolder` | Create Folder | appIntent |
| `DeleteFolder` | Delete Folders | appIntent |
| `DeleteRecording` | Delete Recordings | appIntent |
| `LocationBasedNamingEntity` | Get Location-based Naming | appIntent |
| `LocationBasedNamingEntity-UpdatableEntity` | Edit Location-based Naming | appIntent |
| `OpenFolder` | Open Folder | appIntent |
| `OpenResetAnalyticsIdentifierEntity` | Open Reset Identifier | appIntent |
| `PlaybackVoiceMemoIntent` | Play Recording | appIntent |
| `RCCombineRecordings` | Combine Recordings | appIntent |
| `RCControlCenterToggleRecording` | CONTROL_CENTER_TOGGLE_RECORDING_INTENT_TITLE | appIntent |
| `RCImportRecording` | Import Recording | appIntent |
| `RCRecordingEntity` | Find Recordings | appIntent |
| `RecordVoiceMemoIntent` | Create Recording | appIntent |
| `ResetAnalyticsIdentifierEntity` | Get Reset Identifier | appIntent |
| `SearchRecordings` | Search in Voice Memos | appIntent |
| `SelectRecording` | Select Recording | appIntent |
| `StopRecording` | Stop Recording | appIntent |
| `ToggleRecording` | Voice Memo | appIntent |
| `WFAppSettingEntityUpdaterAction` | Change Voice Memos Settings | appIntent |
| `WFGetAppSettingAction` | Get Voice Memos Settings | appIntent |

## Weather (`com.apple.weather`)

| Intent ID | Name | Type |
|-----------|------|------|
| `AddSavedLocationIntent` | Add Location to List | appIntent |
| `LocationEntity` | Find Location | appIntent |
| `LocationSearchEntity` | Find Location | appIntent |
| `OpenMoonIntent` | Open Moon Details | appIntent |
| `OpenNotificationsConfigurationIntent` | Open Notifications Configuration | appIntent |
| `OpenSunriseSunsetIntent` | Open Sunrise and Sunset Details | appIntent |
| `OpenUnitsConfigurationIntent` | Open Units Configuration | appIntent |
| `OpenWeatherAirQualityIntent` | Open Air Quality Details | appIntent |
| `OpenWeatherSpecificConditionIntent` | Open Weather Condition Details | appIntent |
| `PreferredUnitsEntity` | Find Preferred Weather Units | appIntent |
| `RemoveSavedLocationIntent` | Remove Locations from List | appIntent |
| `ResetUnitsIntent` | Reset Unit | appIntent |
| `SetDistanceUnitIntent` | Set Distance Unit | appIntent |
| `SetPrecipitationUnitIntent` | Set Precipitation Unit | appIntent |
| `SetPressureUnitIntent` | Set Pressure Unit | appIntent |
| `SetTemperatureUnitIntent` | Set Temperature Unit | appIntent |
| `SetWindUnitIntent` | Set Wind Unit | appIntent |
| `WeatherIntent` | Show Weather | siriIntent |

## com.apple.AppStore (`com.apple.AppStore`)

| Intent ID | Name | Type |
|-----------|------|------|
| `SystemSearchIntent` | Search App Store | appIntent |

## com.apple.Desktop-Settings (`com.apple.Desktop-Settings.extension`)

| Intent ID | Name | Type |
|-----------|------|------|
| `OpenDesktopSettingsDeepLink` | Open Desktop & Dock Setting | appIntent |

## com.apple.GameCenter (`com.apple.GameCenter.Settings.DeviceExpertExtension`)

| Intent ID | Name | Type |
|-----------|------|------|
| `OpenGameCenterSettingsDeepLinks` | Open Game Center Settings | appIntent |

## com.apple.GenerativePlaygroundApp (`com.apple.GenerativePlaygroundApp`)

| Intent ID | Name | Type |
|-----------|------|------|
| `GenerateImageIntent` | Create Image | appIntent |

## com.apple.HydraUSDAppIntents (`com.apple.HydraUSDAppIntents`)

| Intent ID | Name | Type |
|-----------|------|------|
| `ConvertToUSDZ` | Convert to USDZ | appIntent |

## com.apple.PeopleViewService (`com.apple.PeopleViewService`)

| Intent ID | Name | Type |
|-----------|------|------|
| `SelectPersonIntent` | Select Person | appIntent |
| `URLAppIntent` | Open URL | appIntent |

## com.apple.Spotlight (`com.apple.Spotlight`)

| Intent ID | Name | Type |
|-----------|------|------|
| `ClearSpotlightIntent` | Clear Current Search | appIntent |
| `SearchFieldEntity` | Get Current Search Query | appIntent |
| `SearchSpotlightIntent` | Open Search | appIntent |
| `SearchSpotlightIntentInternal` | Open Search | appIntent |
| `SearchUIContinuationIntent` | Continue Search in App | appIntent |
| `SearchUIOpenKnowledgeIntent` | Open Siri Knowledge Page | appIntent |
| `ToggleSpotlightIntent` | Show Search | appIntent |

## com.apple.TransparencySettingsIntents (`com.apple.TransparencySettingsIntents`)

| Intent ID | Name | Type |
|-----------|------|------|
| `OpenTransparencyPublicVerificationCodeDeepLink` | Open Contact Key Verification Public Verification Code Settings | appIntent |
| `OpenTransparencyStatusDeepLink` | Open Contact Key Verification Status Settings | appIntent |
| `TransparencyPublicVerificationCodeEntity` | Get Contact Key Verification Public Verification Code | appIntent |
| `TransparencySettingsIntents` | TransparencySettingsIntents | appIntent |
| `TransparencyStatusEntity` | Get Contact Key Verification Status | appIntent |

## com.apple.WindowManager (`com.apple.WindowManager`)

| Intent ID | Name | Type |
|-----------|------|------|
| `AppExposeAction` | Application Windows | appIntent |
| `CornersTileAction` | Tile Windows to Corners | appIntent |
| `MissionControlAction` | Mission Control | appIntent |
| `ShowDesktopAction` | Show Desktop | appIntent |
| `StageManagerToggleIntent` | Enable Stage Manager | appIntent |
| `ThreeUpTileAction` | Tile Windows Left & Corners | appIntent |
| `TwoUpTileAction` | Tile Windows Left & Right | appIntent |

## com.apple.WritingTools (`com.apple.WritingTools.WritingToolsAppIntentsExtension`)

| Intent ID | Name | Type |
|-----------|------|------|
| `AdjustToneIntent` | Adjust Tone of Text | appIntent |
| `FormatListIntent` | Make List from Text | appIntent |
| `FormatTableIntent` | Make Table from Text | appIntent |
| `ProofreadIntent` | Proofread Text | appIntent |
| `RewriteTextIntent` | Rewrite Text | appIntent |
| `SummarizeTextIntent` | Summarize Text | appIntent |

## com.apple.calculator (`com.apple.calculator`)

| Intent ID | Name | Type |
|-----------|------|------|
| `LaunchCalculatorOpenIntent` | Calculator | appIntent |

## com.apple.controlcenter (`com.apple.controlcenter`)

| Intent ID | Name | Type |
|-----------|------|------|
| `DisplaySleepIntent` | Put Display to Sleep | appIntent |
| `LockScreenIntent` | Lock the screen | appIntent |
| `ScreenSaverIntent` | Start Screen Saver | appIntent |
| `SetDarkModeEnabledIntent` | Enable or disable Dark Mode | appIntent |
| `SetNightShiftEnabledIntent` | Enable or disable Night Shift | appIntent |
| `SetTrueToneEnabledIntent` | Enable or disable True Tone | appIntent |

## com.apple.dock (`com.apple.dock`)

| Intent ID | Name | Type |
|-----------|------|------|
| `SetDockAutoHideEnabledIntent` | Automatically hide and show the Dock | appIntent |

## com.apple.donotdisturb (`com.apple.donotdisturb.DoNotDisturbAppIntents`)

| Intent ID | Name | Type |
|-----------|------|------|
| `FocusEntity` | Find FOCUS | appIntent |
| `OpenFocusSettingsDynamicDeepLinks` | Open Focus Settings | appIntent |
| `SetFocusState` | Set Focus | appIntent |

## com.apple.facetime (`com.apple.facetime`)

| Intent ID | Name | Type |
|-----------|------|------|
| `facetime` | FaceTime | siriIntent |

## com.apple.findmy (`com.apple.findmy`)

| Intent ID | Name | Type |
|-----------|------|------|
| `FriendSelectorIntent` | Choose Person | appIntent |
| `Intent` | Preview_Intent_Only | appIntent |
| `ItemEntity` | Find Item | appIntent |
| `ItemSelectorIntent` | Choose Item | appIntent |
| `PersonEntity` | Find Person | appIntent |
| `WidgetItemEntity` | Find Item | appIntent |
| `WidgetPersonEntity` | Find Person | appIntent |

## com.apple.generativeassistanttools (`com.apple.generativeassistanttools.GenerativeAssistantExtension`)

| Intent ID | Name | Type |
|-----------|------|------|
| `GenerateKnowledgeResponseIntent` | Generate Knowledge Response | appIntent |
| `GenerateRichContentFromMediaIntent` | Generate Rich Content From Media | appIntent |
| `GenerateRichContentIntent` | Generate Rich Content | appIntent |
| `PrewarmGenerativeAssistantExtensionIntent` | Prewarm GenerativeAssistantExtension | appIntent |

## com.apple.helpviewer (`com.apple.helpviewer`)

| Intent ID | Name | Type |
|-----------|------|------|
| `CollectionOpenIntent` | Open Collection | appIntent |

## com.apple.homed (`com.apple.homed`)

| Intent ID | Name | Type |
|-----------|------|------|
| `SetPersonalContentSettingIntent` | ChangePersonalContentSettingsIntent | appIntent |

## com.apple.intelligenceflow (`com.apple.intelligenceflow.IntelligenceFlowAppIntentsExtension`)

| Intent ID | Name | Type |
|-----------|------|------|
| `OpenApplication` | Open Application | appIntent |
| `OpenFile` | Open File | appIntent |
| `OpenURL` | Open URL | appIntent |

## com.apple.intelligenceplatform (`com.apple.intelligenceplatform.IntelligencePlatform.IntelligencePlatformDataActionsAppIntentsExtension`)

| Intent ID | Name | Type |
|-----------|------|------|
| `CalculateAppUsageIntent` | Get App & Website Activity | appIntent |
| `FindSportsEvents` | Get Upcoming Sports Events | appIntent |

## com.apple.intelligenceplatformd (`com.apple.intelligenceplatformd`)

| Intent ID | Name | Type |
|-----------|------|------|
| `PersonalKnowledgeTool` | Personal Knowledge Tool | appIntent |

## com.apple.mobilenotes (`com.apple.mobilenotes`)

| Intent ID | Name | Type |
|-----------|------|------|
| `SharingExtension` | Create Note | appIntent |

## com.apple.mobilephone (`com.apple.mobilephone`)

| Intent ID | Name | Type |
|-----------|------|------|
| `call` | Call | siriIntent |

## com.apple.mobileslideshow (`com.apple.mobileslideshow`)

| Intent ID | Name | Type |
|-----------|------|------|
| `StreamShareService` | Post to Shared Album | action |

## com.apple.mobiletimer-framework (`com.apple.mobiletimer-framework.MobileTimerIntents`)

| Intent ID | Name | Type |
|-----------|------|------|
| `MTCreateAlarmIntent` | Add Alarm | appIntent |
| `MTGetAlarmsIntent` | Find Alarms | appIntent |
| `MTToggleAlarmIntent` | Toggle Alarm | appIntent |

## com.apple.musicrecognition (`com.apple.musicrecognition`)

| Intent ID | Name | Type |
|-----------|------|------|
| `RecognizeMusicIntent` | Recognize Music | action |

## com.apple.printcenter (`com.apple.printcenter`)

| Intent ID | Name | Type |
|-----------|------|------|
| `CancelPrintJob` | Cancel Print Job | appIntent |
| `LaunchPrintCenterAppIntent` | Open Print Center | appIntent |
| `PrintDocuments` | Print Documents | appIntent |

## com.apple.wallpaper (`com.apple.wallpaper.agent`)

| Intent ID | Name | Type |
|-----------|------|------|
| `SetWallpaperIntent` | Set Wallpaper | appIntent |
| `SetWallpaperPhotoIntent` | Set Wallpaper Photo | appIntent |
| `SkipShuffledContentAction` | Skip Wallpaper | appIntent |
| `WallpaperEntity` | Find Wallpapers | appIntent |

---

⚠️ = Deprecated

For SiriIntents (type=siriIntent), use `is.workflow.actions.handleintent` instead of `appintentexecution`.
