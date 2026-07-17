<?xml version="1.0"?>
<!-- The provider hardcodes the cloud-init ISO onto an IDE bus, which the q35
     machine type does not have; rewrite the cdrom to SATA. -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:template match="@*|node()">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()"/>
    </xsl:copy>
  </xsl:template>

  <xsl:template match="disk[@device='cdrom']/target/@bus">
    <xsl:attribute name="bus">sata</xsl:attribute>
  </xsl:template>

  <xsl:template match="disk[@device='cdrom']/target/@dev">
    <xsl:attribute name="dev">sda</xsl:attribute>
  </xsl:template>
</xsl:stylesheet>
