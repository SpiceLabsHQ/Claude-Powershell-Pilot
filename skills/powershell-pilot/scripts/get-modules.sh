#!/bin/bash
pwsh -NoProfile -c "(Get-Module -ListAvailable | Select-Object -ExpandProperty Name | Sort-Object -Unique) -join ', '" 2>/dev/null || echo "NOT INSTALLED"
