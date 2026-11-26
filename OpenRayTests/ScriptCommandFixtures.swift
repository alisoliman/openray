import Foundation

// Script headers copied verbatim from the public Script Commands repository, used as parser
// fixtures. Only the comment headers are kept (plus a harmless last line), not the scripts' code.
//
// Source: https://github.com/raycast/script-commands (templates/ and commands/)
// MIT License, Copyright (c) 2020-2021 Raycast Technologies Ltd.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software
// and associated documentation files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions: The above copyright notice
// and this permission notice shall be included in all copies or substantial portions of the
// Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

enum ScriptFixtures {
    /// templates/script-command.template.sh
    static let bashTemplate = """
        #!/bin/bash

        # Raycast Script Command Template
        #
        # Duplicate this file and remove ".template" from the filename to get started.
        # See full documentation here: https://github.com/raycast/script-commands
        #
        # Required parameters:
        # @raycast.schemaVersion 1
        # @raycast.title My First Script
        # @raycast.mode fullOutput
        # @raycast.packageName Raycast Scripts
        #
        # Optional parameters:
        # @raycast.icon 🤖
        # @raycast.currentDirectoryPath ~
        # @raycast.needsConfirmation false
        #
        # Documentation:
        # @raycast.description Write a nice and descriptive summary about your script command here
        # @raycast.author Your name
        # @raycast.authorURL An URL for one of your social medias

        echo "Hello from My First Script"
        """

    /// templates/script-command.template.swift
    static let swiftTemplate = """
        #!/usr/bin/swift

        // Raycast Script Command Template
        //
        // Duplicate this file and remove ".template" from the filename to get started.
        // See full documentation here: https://github.com/raycast/script-commands
        //
        // Required parameters:
        // @raycast.schemaVersion 1
        // @raycast.title My First Script
        // @raycast.mode fullOutput
        // @raycast.packageName Raycast Scripts
        //
        // Optional parameters:
        // @raycast.icon 🤖
        // @raycast.currentDirectoryPath ~
        // @raycast.needsConfirmation false
        //
        // Documentation:
        // @raycast.description Write a nice and descriptive summary about your script command here
        // @raycast.author Your name
        // @raycast.authorURL An URL for one of your social medias

        print("Hello from My First Script")
        """

    /// templates/script-command.template.py
    static let pythonTemplate = """
        #!/usr/bin/env python3

        # Raycast Script Command Template
        #
        # Dependency: This script requires Python 3
        # Install Python 3: https://www.python.org/downloads/release
        #
        # Duplicate this file and remove ".template" from the filename to get started.
        # See full documentation here: https://github.com/raycast/script-commands
        #
        # Required parameters:
        # @raycast.schemaVersion 1
        # @raycast.title My First Script
        # @raycast.mode fullOutput
        # @raycast.packageName Raycast Scripts
        #
        # Optional parameters:
        # @raycast.icon 🤖
        # @raycast.currentDirectoryPath ~
        # @raycast.needsConfirmation false
        #
        # Documentation:
        # @raycast.description Write a nice and descriptive summary about your script command here
        # @raycast.author Your name
        # @raycast.authorURL An URL for one of your social medias

        print("Hello World!")
        """

    /// templates/script-command.template.js
    static let javaScriptTemplate = """
        #!/usr/bin/env node

        // Raycast Script Command Template
        //
        // Dependency: This script requires Nodejs.
        // Install Node: https://nodejs.org/en/download/
        //
        // Duplicate this file and remove ".template" from the filename to get started.
        // See full documentation here: https://github.com/raycast/script-commands
        //
        // Required parameters:
        // @raycast.schemaVersion 1
        // @raycast.title My First Script
        // @raycast.mode fullOutput
        // @raycast.packageName Raycast Scripts
        //
        // Optional parameters:
        // @raycast.icon 🤖
        // @raycast.argument1 { "type": "text", "placeholder": "js, css, html", "optional": true}
        // @raycast.argument2 { "type": "text", "placeholder": "query" }
        //
        // Documentation:
        // @raycast.description Write a nice and descriptive summary about your script command here
        // @raycast.author Your name
        // @raycast.authorURL An URL for one of your social medias

        console.log("done")
        """

    /// commands/system/inline-cpu-usage-percent.sh
    static let inlineCPU = """
        #!/bin/bash

        # Required parameters:
        # @raycast.schemaVersion 1
        # @raycast.title CPU Usage
        # @raycast.mode inline
        # @raycast.packageName System
        # @raycast.refreshTime 10s

        # Optional parameters:
        # @raycast.icon 🖥️

        # Documentation:
        # @raycast.description Display CPU usage percent
        # @raycast.author Juan Luis Romero
        # @raycast.authorURL https://github.com/JuanluR8

        echo "CPU Usage: 1%"
        """

    /// commands/system/caffeinate-status.swift
    static let caffeinateStatus = """
        #!/usr/bin/swift

        // Required parameters:
        // @raycast.schemaVersion 1
        // @raycast.title Caffeinate
        // @raycast.mode inline
        // @raycast.packageName System
        // @raycast.refreshTime 30s
        //
        // Optional parameters:
        // @raycast.icon ☕️
        // @raycast.needsConfirmation false
        //
        // Documentation:
        // @raycast.description Shows caffeinate status and time left if it's running
        // @raycast.author Yan Smaliak
        // @raycast.authorURL https://github.com/ysmaliak

        import Foundation
        """

    /// commands/web-searches/check-weather.sh
    static let checkWeather = """
        #!/bin/bash

        # Required parameters:
        # @raycast.schemaVersion 1
        # @raycast.title Check Weather
        # @raycast.mode silent

        # Optional parameters:
        # @raycast.icon 🌦
        # @raycast.packageName wttr.in
        # @raycast.argument1 { "type": "text", "placeholder": "Location", "optional": true}
        # @raycast.argument2 { "type": "text", "placeholder": "Options", "optional": true}

        # Documentation:
        # @raycast.author Jakub Lanski
        # @raycast.authorURL https://github.com/jaklan

        echo "weather"
        """

    /// commands/apps/amphetamine/amphetamine-on.applescript (keys out of the usual order)
    static let amphetamineOn = """
        #!/usr/bin/osascript

        # Install Amphetamine via Mac App Store: https://apps.apple.com/us/app/amphetamine/id937984704

        # @raycast.title Start Default Session
        # @raycast.author James Lyons
        # @raycast.authorURL https://github.com/jamesjlyons
        # @raycast.description Start Default Amphetamine Session

        # @raycast.icon images/amphetamine.png
        # @raycast.mode silent
        # @raycast.packageName Amphetamine
        # @raycast.schemaVersion 1

        log "Started default session"
        """

    /// commands/apps/timing/timing-start-timer.js (JavaScript for Automation, three optional arguments)
    static let timingStartTimer = """
        #!/usr/bin/osascript -l JavaScript

        // Note: Timing.app is required with an Expert or Connect subscription
        // Learn more and install: https://timingapp.com

        // Required parameters:
        // @raycast.schemaVersion 1
        // @raycast.title Start Timer
        // @raycast.mode silent

        // Optional parameters:
        // @raycast.icon images/timing-logo.png
        // @raycast.argument1 { "type": "text", "placeholder": "Project", "optional": true }
        // @raycast.argument2 { "type": "text", "placeholder": "Title", "optional": true }
        // @raycast.argument3 { "type": "text", "placeholder": "Duration", "optional": true }
        // @raycast.packageName Timing

        // Documentation:
        // @raycast.description Start a timer
        // @raycast.author Landen Danyluk
        // @raycast.authorURL https://github.com/landendanyluk
        """

    /// documentation/ARGUMENTS.md's two-argument example.
    static let searchFlights = """
        #!/bin/bash

        # Required parameters:
        # @raycast.schemaVersion 1
        # @raycast.title Search Flights
        # @raycast.mode silent

        # Optional parameters:
        # @raycast.icon 🛩
        # @raycast.packageName Web Searches
        # @raycast.argument1 { "type": "text", "placeholder": "from city", "percentEncoded": true }
        # @raycast.argument2 { "type": "text", "placeholder": "to city", "optional": true, "percentEncoded": true }

        echo "flights"
        """
}
